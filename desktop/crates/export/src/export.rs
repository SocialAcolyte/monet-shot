//! The export: every frame of the edit painted from its FramePlan and
//! encoded, with the sound the Mac's `Composer` lays under it (camera voices
//! and the music, faded and ducked).

use crate::ffmpeg::{self, command, decode_audio, pick_encoder, probe, tools, ExportError, VideoReader, FPS, RATE};
use crate::paint::{shrink, Painter, Rgba8};
use monetshot_core::camera::music_envelope;
use monetshot_core::plan::Planner;
use monetshot_core::timemap::TimeMap;
use monetshot_core::Project;
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::sync_channel;
use std::sync::Arc;

/// Where someone is talking, and the sound itself, laid on the output timeline.
struct Placed {
    file: PathBuf,
    from: f64,
    duration: f64,
    at: f64,
}

/// The camera sound pieces, as `Composer.addCamera` places them: clips
/// recorded over the edit, and each take's own camera following its clips.
fn camera_audio(project: &Project, map: &TimeMap) -> Vec<Placed> {
    let mut out = vec![];
    let mut clips = project.edit.camera_clips.clone();
    clips.sort_by(|a, b| a.at.total_cmp(&b.at));
    for c in clips {
        let file = project.folder.join(&c.file);
        let Ok(p) = probe(&file) else { continue };
        let to = c.duration.min(p.duration).min(map.duration() - c.at);
        if to > 0.05 && p.has_audio {
            out.push(Placed { file, from: 0.0, duration: to, at: c.at });
        }
    }
    for s in &map.spans {
        let Some(take) = usize::try_from(s.take).ok().and_then(|i| project.takes.get(i)) else { continue };
        let Some(file) = take.camera_path() else { continue };
        let Ok(p) = probe(&file) else { continue };
        let off = take.meta.camera_offset;
        let from = (s.start - off).max(0.0);
        let to = p.duration.min(s.end - off);
        if to - from > 0.05 && p.has_audio {
            out.push(Placed { file, from, duration: to - from, at: s.at + (from - (s.start - off)) });
        }
    }
    out
}

/// The music's gain at each sample, as the Mac's audio mix sets it: sampled
/// every 0.1 s, ramping where it changes, holding where it doesn't.
fn music_gains(length: f64, volume: f64, fade_in: bool, fade_out: bool, voice: &[(f64, f64)]) -> Vec<(f64, f64, f32, f32)> {
    let v = volume.clamp(0.0, 1.0) as f32;
    let gain = |t: f64| v * music_envelope::gain(t, length, fade_in, fade_out, voice) as f32;
    let mut steps = vec![];
    let (mut t, mut held) = (0.0, None::<f32>);
    while t < length - 0.001 {
        let next = (t + 0.1).min(length);
        let (a, b) = (gain(t), gain(next));
        if (a - b).abs() > 0.0005 {
            steps.push((t, next, a, b));
            held = None;
        } else {
            let h = *held.get_or_insert(a);
            steps.push((t, next, h, h));
        }
        t = next;
    }
    steps
}

/// The edit's sound, interleaved stereo at 44.1 kHz; None when there is none.
fn mix_audio(project: &Project, map: &TimeMap) -> Result<Option<Vec<f32>>, ExportError> {
    let length = map.duration();
    let n = (length * RATE as f64).ceil() as usize;
    let mut mix = vec![0f32; n * 2];
    let mut any = false;
    let pieces = camera_audio(project, map);
    for p in &pieces {
        let pcm = decode_audio(&p.file, p.from, Some(p.duration), 2, RATE)?;
        let start = (p.at * RATE as f64).round() as usize * 2;
        for (i, s) in pcm.iter().enumerate() {
            if let Some(m) = mix.get_mut(start + i) {
                *m += s;
                any = true;
            }
        }
    }
    if let Some(m) = &project.edit.music {
        let song_file = project.folder.join(&m.file);
        let song = if song_file.exists() { decode_audio(&song_file, 0.0, None, 2, RATE)? } else { vec![] };
        let song_len = song.len() as f64 / 2.0 / RATE as f64;
        if song_len > 0.5 && length > 0.0 {
            let voice: Vec<(f64, f64)> =
                if project.edit.camera_look.duck_music { pieces.iter().map(|p| (p.at, p.at + p.duration)).collect() } else { vec![] };
            let steps = music_gains(length, m.volume, m.fade_in, m.fade_out, &voice);
            let gain_at = |t: f64| -> f32 {
                let i = ((t / 0.1) as usize).min(steps.len().saturating_sub(1));
                steps.get(i).map_or(0.0, |&(a, b, ga, gb)| {
                    let u = if b > a { ((t - a) / (b - a)).clamp(0.0, 1.0) as f32 } else { 0.0 };
                    ga + (gb - ga) * u
                })
            };
            // From `offset` into the song, and from the top again if it runs out.
            let mut from = m.offset.max(0.0).min(song_len - 0.5);
            let mut at = 0.0;
            while at < length - 0.01 {
                let take = (song_len - from).min(length - at);
                let (s0, o0) = ((from * RATE as f64).round() as usize, (at * RATE as f64).round() as usize);
                let count = (take * RATE as f64).round() as usize;
                for k in 0..count {
                    let (si, oi) = (s0 + k, o0 + k);
                    if si * 2 + 1 >= song.len() || oi * 2 + 1 >= mix.len() {
                        break;
                    }
                    let g = gain_at(oi as f64 / RATE as f64);
                    mix[oi * 2] += song[si * 2] * g;
                    mix[oi * 2 + 1] += song[si * 2 + 1] * g;
                }
                any = true;
                at += take;
                from = 0.0;
            }
        }
    }
    Ok(any.then_some(mix))
}

/// The video files a project reads, opened once.
struct Readers {
    folder: PathBuf,
    open: HashMap<PathBuf, Option<VideoReader>>,
}

impl Readers {
    fn frame(&mut self, path: &Path, time: f64) -> Result<Option<Arc<Rgba8>>, ExportError> {
        let r = self.open.entry(path.to_path_buf()).or_insert_with(|| VideoReader::open(path).ok());
        match r {
            Some(r) => r.frame_at(time),
            None => Ok(None),
        }
    }
}

/// The source and webcam frames for output time `t`, painted.
fn render_frame(project: &Project, planner: &Planner, painter: &mut Painter, readers: &mut Readers, t: f64) -> Result<Rgba8, ExportError> {
    let plan = planner.plan(t);
    let take = usize::try_from(plan.take).ok().and_then(|i| project.takes.get(i)).unwrap_or(&project.takes[0]);
    let source = readers
        .frame(&take.video_path(), plan.take_time)?
        .unwrap_or_else(|| Arc::new(Rgba8::new(16, 9, [0, 0, 0, 255].repeat(16 * 9))));
    // The first candidate with a frame (an overlay clip wins over the take's camera).
    let mut webcam = None;
    for (i, w) in plan.webcam.iter().enumerate() {
        let path = readers.folder.join(&w.file);
        if let Some(f) = readers.frame(&path, w.time)? {
            webcam = Some((i, f));
            break;
        }
    }
    Ok(painter.paint(&plan, &source, webcam.as_ref().map(|(i, f)| (*i, f.as_ref()))))
}

/// Progress callback: 0...1.
pub type Progress<'a> = &'a (dyn Fn(f64) + Sync);

/// Renders the edit to an .mp4 at `out` (replacing it). `cancel` stops it
/// (the partial file is removed). Writes `<name>.credits.txt` beside it when
/// the music asks for a credit, as the Mac does.
pub fn export(project: &Project, out: &Path, progress: Progress, cancel: &AtomicBool) -> Result<(), ExportError> {
    let t = tools()?;
    let planner = Planner::from_project(project);
    let mut painter = Painter::new(&planner, Some(&project.folder));
    let (w, h) = painter.size();
    let length = planner.duration();
    // AVFoundation renders every frame that starts before the end.
    let frames = ((length * FPS - 1e-6).ceil() as usize).max(1);
    let tmp_dir = std::env::temp_dir().join(format!("monetshot-export-{}-{}", std::process::id(), frames));
    std::fs::create_dir_all(&tmp_dir)?;
    let cleanup = scopeguard(tmp_dir.clone());

    let audio = mix_audio(project, &planner.map)?;
    let wav = tmp_dir.join("sound.wav");
    if let Some(a) = &audio {
        ffmpeg::write_wav(&wav, a, RATE)?;
    }

    // HEVC above 4K-ish widths, H.264 otherwise (as the Mac).
    let enc = pick_encoder(w > 3000)?;
    let partial = out.with_extension("partial.mp4");
    let mut cmd = command(&t.ffmpeg);
    cmd.args(["-v", "error", "-y"]).args(ffmpeg::input_args(&enc));
    cmd.args(["-f", "rawvideo", "-pix_fmt", "rgba", "-s", &format!("{w}x{h}"), "-r", &FPS.to_string(), "-i", "-"]);
    if audio.is_some() {
        cmd.arg("-i").arg(&wav);
    }
    cmd.args(["-vf", &ffmpeg::filter(&enc), "-c:v", &enc.name]).args(&enc.args);
    cmd.args(["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"]);
    if audio.is_some() {
        cmd.args(["-c:a", "aac", "-b:a", "192k"]);
    }
    cmd.args(["-movflags", "+faststart", "-f", "mp4"]).arg(&partial);
    let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped()).spawn()?;
    let mut stdin = child.stdin.take().unwrap();
    // Frames go to the encoder on their own thread, so painting the next
    // one overlaps encoding this one.
    let (to_encoder, frames_rx) = sync_channel::<Rgba8>(2);
    let writer = std::thread::spawn(move || -> bool {
        for f in frames_rx {
            if stdin.write_all(&f.data).is_err() {
                return false;
            }
        }
        true
    });
    let stderr = child.stderr.take().unwrap();
    let err_reader = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = std::io::Read::read_to_string(&mut { stderr }, &mut s);
        s
    });

    let mut readers = Readers { folder: project.folder.clone(), open: HashMap::new() };
    let mut result = Ok(());
    for i in 0..frames {
        if cancel.load(Ordering::Relaxed) {
            result = Err(ExportError::Cancelled);
            break;
        }
        let t = i as f64 / FPS;
        let frame = match render_frame(project, &planner, &mut painter, &mut readers, t) {
            Ok(f) => f,
            Err(e) => {
                result = Err(e);
                break;
            }
        };
        if to_encoder.send(frame).is_err() {
            result = Err(ExportError::Ffmpeg("the encoder stopped".into()));
            break;
        }
        progress((i + 1) as f64 / frames as f64 * 0.99);
    }
    drop(to_encoder);
    if result.is_err() {
        let _ = child.kill();
    }
    let wrote_all = writer.join().unwrap_or(false);
    if result.is_ok() && !wrote_all {
        result = Err(ExportError::Ffmpeg("the encoder stopped".into()));
    }
    let status = child.wait()?;
    let errors = err_reader.join().unwrap_or_default();
    drop(cleanup);
    if let Err(e) = result {
        let _ = std::fs::remove_file(&partial);
        return Err(e);
    }
    if !status.success() {
        let _ = std::fs::remove_file(&partial);
        return Err(ExportError::Ffmpeg(errors.lines().rev().take(3).collect::<Vec<_>>().join(" | ")));
    }
    let _ = std::fs::remove_file(out);
    std::fs::rename(&partial, out)?;
    // CC BY music asks for a credit wherever the video goes: keep it beside the file.
    let credit = out.with_extension("credits.txt");
    match &project.edit.music {
        Some(m) if m.track.needs_credit() => std::fs::write(&credit, m.track.credit_text())?,
        _ => {
            let _ = std::fs::remove_file(&credit);
        }
    }
    progress(1.0);
    Ok(())
}

struct Guard(PathBuf);
impl Drop for Guard {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn scopeguard(p: PathBuf) -> Guard {
    Guard(p)
}

/// Where the Mac puts an export: beside the .reel, named like it.
pub fn default_output(project: &Project) -> PathBuf {
    project.folder.with_file_name(format!("{}.mp4", project.name()))
}

// MARK: stills and thumbnails

/// One finished frame at output time `t`, exactly as the export draws it,
/// shrunk to `max_width` if given.
pub fn render_still(project: &Project, t: f64, max_width: Option<u32>) -> Result<Rgba8, ExportError> {
    let planner = Planner::from_project(project);
    let mut painter = Painter::new(&planner, Some(&project.folder));
    let mut readers = Readers { folder: project.folder.clone(), open: HashMap::new() };
    let t = t.clamp(0.0, (planner.duration() - 0.02).max(0.0));
    let img = render_frame(project, &planner, &mut painter, &mut readers, t)?;
    Ok(match max_width {
        Some(mw) => shrink(&img, mw),
        None => img,
    })
}

/// When the Home card's picture is taken: min(1.5, duration / 3).
pub fn thumb_time(project: &Project) -> f64 {
    1.5f64.min(project.meta().duration / 3.0)
}

/// `<reel>/thumb.jpg` is at least as new as its edit.json.
pub fn thumb_is_fresh(reel: &Path) -> bool {
    let modified = |p: PathBuf| std::fs::metadata(p).and_then(|m| m.modified()).ok();
    match (modified(reel.join("thumb.jpg")), modified(reel.join("edit.json"))) {
        (Some(t), Some(e)) => t >= e,
        (Some(_), None) => true,
        _ => false,
    }
}

/// Renders the Home card picture to `<reel>/thumb.jpg` (640 wide, JPEG 80%),
/// the same file the Mac's Home caches.
pub fn write_thumb(project: &Project) -> Result<PathBuf, ExportError> {
    let img = render_still(project, thumb_time(project), Some(640))?;
    let rgb: Vec<u8> = img.data.chunks(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
    let path = project.folder.join("thumb.jpg");
    // A name of its own per call: two thumbnails of one take can be written at
    // once (home asks right as a recording stops), and a shared tmp file
    // would be renamed away under the second.
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = project.folder.join(format!(".thumb.jpg.{}-{n}.tmp", std::process::id()));
    {
        let f = std::io::BufWriter::new(std::fs::File::create(&tmp)?);
        image::codecs::jpeg::JpegEncoder::new_with_quality(f, 80)
            .encode(&rgb, img.width, img.height, image::ExtendedColorType::Rgb8)
            .map_err(|e| ExportError::Io(std::io::Error::other(e)))?;
    }
    std::fs::rename(&tmp, &path)?;
    Ok(path)
}

/// Encodes an image as PNG bytes.
pub fn png(img: &Rgba8) -> Result<Vec<u8>, ExportError> {
    let mut out = vec![];
    image::codecs::png::PngEncoder::new(&mut out)
        .write_image_rgba(img)
        .map_err(|e| ExportError::Io(std::io::Error::other(e)))?;
    Ok(out)
}

trait PngExt {
    fn write_image_rgba(self, img: &Rgba8) -> image::ImageResult<()>;
}

impl<W: Write> PngExt for image::codecs::png::PngEncoder<W> {
    fn write_image_rgba(self, img: &Rgba8) -> image::ImageResult<()> {
        use image::ImageEncoder;
        self.write_image(&img.data, img.width, img.height, image::ExtendedColorType::Rgba8)
    }
}
