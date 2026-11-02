//! The encoder clock: raw frames in, a constant-frame-rate `screen.mp4` out.
//!
//! Windows.Graphics.Capture and PipeWire deliver a frame only when the
//! screen changes. The clock writes the latest one to ffmpeg's stdin every
//! 1/fps s, repeating it while nothing changes, so frame n of the file is
//! the screen at `t0 + n/fps` and the cursor log needs no timestamp map.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::ffmpeg::{Encoder, Ffmpeg};
use crate::CaptureError;

/// Pixel layouts the backends hand over, 4 bytes per pixel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PixelFormat {
    Bgra,
    Bgrx,
    Rgba,
    Rgbx,
}

impl PixelFormat {
    fn ffmpeg(self) -> &'static str {
        match self {
            PixelFormat::Bgra => "bgra",
            PixelFormat::Bgrx => "bgr0",
            PixelFormat::Rgba => "rgba",
            PixelFormat::Rgbx => "rgb0",
        }
    }
}

/// One captured frame. `stride` is bytes per row (may exceed width * 4).
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub data: Vec<u8>,
}

/// Where backends drop frames; cheap to clone, safe from any thread.
#[derive(Clone)]
pub struct FrameSlot(Arc<Mutex<Option<Arc<Frame>>>>);

impl FrameSlot {
    pub fn put(&self, f: Frame) {
        *self.0.lock().unwrap() = Some(Arc::new(f));
    }
    fn latest(&self) -> Option<Arc<Frame>> {
        self.0.lock().unwrap().clone()
    }
}

pub struct Pipe {
    slot: FrameSlot,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<Result<PipeResult, CaptureError>>>,
}

pub struct PipeResult {
    pub file: PathBuf,
    /// Frames written / fps: the file's length.
    pub duration: f64,
}

/// The size the file gets: even, as H.264 in yuv420p wants.
pub fn even(w: u32, h: u32) -> (u32, u32) {
    ((w & !1).max(2), (h & !1).max(2))
}

impl Pipe {
    /// Spawns ffmpeg for `width`×`height` (made even) at `fps` and the clock
    /// thread. `on_first` runs with the instant the first frame was written:
    /// time zero of the recording.
    pub fn start(
        ff: &Ffmpeg,
        encoder: Encoder,
        out: &Path,
        (width, height): (u32, u32),
        format: PixelFormat,
        fps: u32,
        on_first: impl FnOnce(Instant) + Send + 'static,
    ) -> Result<Pipe, CaptureError> {
        let (w, h) = even(width, height);
        let mut cmd = ff.command();
        cmd.args(encoder.input_args())
            .args(["-f", "rawvideo", "-pix_fmt", format.ffmpeg()])
            .args(["-s", &format!("{w}x{h}"), "-framerate", &fps.to_string(), "-i", "-"])
            .args(encoder.args(fps))
            .args(["-movflags", "+faststart", "-an"])
            .arg(out)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| CaptureError::Ffmpeg(format!("could not start ffmpeg: {e}")))?;
        let stdin = child.stdin.take().expect("piped stdin");
        let slot = FrameSlot(Arc::new(Mutex::new(None)));
        let stop = Arc::new(AtomicBool::new(false));
        let (s2, stop2, file) = (slot.clone(), stop.clone(), out.to_path_buf());
        let thread = std::thread::Builder::new()
            .name("monetshot-encode".into())
            .spawn(move || run(child, stdin, s2, stop2, (w, h), fps, file, on_first))
            .map_err(|e| CaptureError::Other(e.to_string()))?;
        Ok(Pipe { slot, stop, thread: Some(thread) })
    }

    pub fn slot(&self) -> FrameSlot {
        self.slot.clone()
    }

    /// Writes up to now, closes the file and waits for ffmpeg.
    pub fn finish(mut self) -> Result<PipeResult, CaptureError> {
        self.stop.store(true, Ordering::SeqCst);
        match self.thread.take().map(|t| t.join()) {
            Some(Ok(r)) => r,
            _ => Err(CaptureError::Other("the encoder thread panicked".into())),
        }
    }
}

impl Drop for Pipe {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn run(
    mut child: Child,
    mut stdin: ChildStdin,
    slot: FrameSlot,
    stop: Arc<AtomicBool>,
    (w, h): (u32, u32),
    fps: u32,
    file: PathBuf,
    on_first: impl FnOnce(Instant),
) -> Result<PipeResult, CaptureError> {
    let stderr = child.stderr.take();
    let errors = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(mut e) = stderr {
            let _ = std::io::Read::read_to_string(&mut e, &mut s);
        }
        s
    });
    let mut buf = vec![0u8; (w * h * 4) as usize];

    // Wait for the first frame; nothing is written (and time doesn't start) before it.
    let first = loop {
        if stop.load(Ordering::SeqCst) {
            drop(stdin);
            let _ = child.wait();
            let _ = std::fs::remove_file(&file);
            return Err(CaptureError::Other("no frame arrived before the recording was stopped".into()));
        }
        if let Some(f) = slot.latest() {
            break f;
        }
        std::thread::sleep(Duration::from_millis(2));
    };
    let mut current = first;
    pack(&current, &mut buf, w, h);
    let write = |stdin: &mut ChildStdin, buf: &[u8]| stdin.write_all(buf);
    let failed = |child: &mut Child, errors: JoinHandle<String>, e: std::io::Error| {
        let _ = child.wait();
        let detail = errors.join().unwrap_or_default();
        CaptureError::Ffmpeg(format!("ffmpeg stopped taking frames ({e}): {}", detail.trim()))
    };
    if let Err(e) = write(&mut stdin, &buf) {
        return Err(failed(&mut child, errors, e));
    }
    let t0 = Instant::now();
    on_first(t0);
    let mut n: u64 = 1;
    let mut warned = false;
    loop {
        let due = t0 + Duration::from_secs_f64(n as f64 / fps as f64);
        let stopping = stop.load(Ordering::SeqCst);
        if stopping && Instant::now() < due {
            break;
        }
        wait_until(due);
        if let Some(f) = slot.latest() {
            if !Arc::ptr_eq(&f, &current) {
                current = f;
                pack(&current, &mut buf, w, h);
            }
        }
        if let Err(e) = write(&mut stdin, &buf) {
            return Err(failed(&mut child, errors, e));
        }
        n += 1;
        let lag = Instant::now().saturating_duration_since(due);
        if lag > Duration::from_secs(1) && !warned {
            warned = true;
            log::warn!("encoder is {:.1}s behind real time", lag.as_secs_f64());
        }
    }
    drop(stdin);
    let status = child.wait().map_err(|e| CaptureError::Ffmpeg(e.to_string()))?;
    let detail = errors.join().unwrap_or_default();
    if !status.success() {
        return Err(CaptureError::Ffmpeg(format!("ffmpeg failed ({status}): {}", detail.trim())));
    }
    Ok(PipeResult { file, duration: n as f64 / fps as f64 })
}

/// Sleeps most of the way, then yields: plain sleeps overshoot by a
/// scheduler tick on Windows, which is most of a 60 fps frame.
fn wait_until(due: Instant) {
    loop {
        let now = Instant::now();
        if now >= due {
            return;
        }
        let left = due - now;
        if left > Duration::from_millis(3) {
            std::thread::sleep(left - Duration::from_millis(2));
        } else {
            std::thread::yield_now();
        }
    }
}

/// Copies `f` into a tight `w`×`h` buffer: cropped if larger (odd edge, a
/// window that grew), black where smaller (a window that shrank).
fn pack(f: &Frame, buf: &mut [u8], w: u32, h: u32) {
    let row = (w * 4) as usize;
    let copy_w = (f.width.min(w) * 4) as usize;
    let rows = f.height.min(h) as usize;
    if f.width == w && f.stride == row && f.height >= h {
        buf.copy_from_slice(&f.data[..row * h as usize]);
        return;
    }
    if copy_w < row || rows < h as usize {
        buf.fill(0);
    }
    for y in 0..rows {
        let src = &f.data[y * f.stride..y * f.stride + copy_w];
        buf[y * row..y * row + copy_w].copy_from_slice(src);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pack_crops_and_pads() {
        // 3x3 source with stride 16 into 2x2.
        let f = Frame { width: 3, height: 3, stride: 16, data: (0..48).collect() };
        let mut buf = vec![9u8; 16];
        pack(&f, &mut buf, 2, 2);
        assert_eq!(&buf[..8], &[0, 1, 2, 3, 4, 5, 6, 7]);
        assert_eq!(&buf[8..], &[16, 17, 18, 19, 20, 21, 22, 23]);
        // 1x1 into 2x2: the rest is black.
        let f = Frame { width: 1, height: 1, stride: 4, data: vec![1, 2, 3, 4] };
        pack(&f, &mut buf, 2, 2);
        assert_eq!(buf, [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn even_sizes() {
        assert_eq!(even(1921, 1081), (1920, 1080));
        assert_eq!(even(1, 1), (2, 2));
    }

    /// Feeds a moving square for 1 s and checks the file is CFR and as long
    /// as the wall time. Needs ffmpeg; skipped without it.
    #[test]
    fn writes_constant_rate_file() {
        let Ok(ff) = crate::ffmpeg::ffmpeg() else { return };
        let dir = std::env::temp_dir().join(format!("monetshot-pipe-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let out = dir.join("screen.mp4");
        let started = Arc::new(Mutex::new(None));
        let s2 = started.clone();
        let pipe = Pipe::start(&ff, Encoder::X264, &out, (321, 241), PixelFormat::Bgra, 30, move |t| {
            *s2.lock().unwrap() = Some(t);
        })
        .unwrap();
        let slot = pipe.slot();
        // Frames arrive irregularly, as from a compositor.
        for i in 0..8u32 {
            let mut data = vec![40u8; 321 * 241 * 4];
            for y in 0..20 {
                for x in (i * 30)..(i * 30 + 20) {
                    let p = ((y * 321 + x) * 4) as usize;
                    data[p..p + 4].copy_from_slice(&[255, 255, 255, 255]);
                }
            }
            slot.put(Frame { width: 321, height: 241, stride: 321 * 4, data });
            std::thread::sleep(Duration::from_millis(125));
        }
        let r = pipe.finish().unwrap();
        assert!(started.lock().unwrap().is_some());
        assert!((r.duration - 1.0).abs() < 0.15, "duration {}", r.duration);
        let probed = ff.duration(&out).unwrap();
        assert!((probed - r.duration).abs() < 0.05, "probed {probed} vs {}", r.duration);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
