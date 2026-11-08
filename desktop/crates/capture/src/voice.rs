//! Your voice without the camera: the microphone alone into `voice.m4a`
//! beside the screen (the Mac's `VoiceRecorder`). One ffmpeg process; a
//! trickle of raw samples on stdout tells us when the file's first sound
//! arrived, which is the moment the file starts.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::ffmpeg::{ffmpeg, NoWindow};
use crate::CaptureError;

pub struct VoiceRec {
    child: Child,
    stdin: Option<ChildStdin>,
    file: PathBuf,
}

/// The ffmpeg input for microphone `mic` ("default" or None = the system's).
pub fn input_args(mic: Option<&str>) -> Result<Vec<String>, CaptureError> {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    if cfg!(target_os = "linux") {
        let mut a = s(&["-f", "pulse", "-thread_queue_size", "512", "-i"]);
        a.push(mic.unwrap_or("default").to_string());
        Ok(a)
    } else if cfg!(windows) {
        let name = match mic.filter(|m| *m != "default") {
            Some(m) => m.to_string(),
            None => crate::camera::microphones()?.first().map(|d| d.id.clone()).ok_or_else(|| CaptureError::Other("no microphone".into()))?,
        };
        let mut a = s(&["-f", "dshow", "-i"]);
        a.push(format!("audio={name}"));
        Ok(a)
    } else {
        let mut a = s(&["-f", "avfoundation", "-i"]);
        a.push(format!(":{}", mic.filter(|m| *m != "default").unwrap_or("0")));
        Ok(a)
    }
}

impl VoiceRec {
    /// Starts `path` from microphone `mic`; returns once the first sound
    /// arrived, with that instant.
    pub fn start(mic: Option<&str>, path: &Path) -> Result<(VoiceRec, Instant), CaptureError> {
        let ff = ffmpeg()?;
        let _ = std::fs::remove_file(path);
        let mut cmd = Command::new(&ff.ffmpeg);
        cmd.args(["-hide_banner", "-loglevel", "error", "-y"]).no_window();
        cmd.args(input_args(mic)?);
        cmd.args(["-map", "0:a", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]).arg(path);
        // The trickle: 8-bit mono at 200 Hz, only to see the first sound.
        cmd.args(["-map", "0:a", "-ac", "1", "-ar", "200", "-f", "u8", "pipe:1"]);
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| CaptureError::Ffmpeg(format!("could not start ffmpeg: {e}")))?;
        let stdin = child.stdin.take();
        let mut stdout = child.stdout.take().expect("stdout");
        let mut stderr = child.stderr.take().expect("stderr");
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut buf = [0u8; 256];
            let mut first = true;
            while let Ok(n) = stdout.read(&mut buf) {
                if n == 0 {
                    break;
                }
                if first {
                    first = false;
                    let _ = tx.send(Instant::now());
                }
            }
        });
        let (etx, erx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut s = String::new();
            let _ = stderr.read_to_string(&mut s);
            let s = s.trim().to_string();
            if !s.is_empty() {
                log::error!("voice ffmpeg: {s}");
            }
            let _ = etx.send(s);
        });
        let mut rec = VoiceRec { child, stdin, file: path.to_path_buf() };
        match rx.recv_timeout(Duration::from_secs(6)) {
            Ok(at) => {
                log::info!("voice recording: {}", path.display());
                Ok((rec, at))
            }
            Err(_) => {
                rec.end();
                let detail = erx.recv_timeout(Duration::from_millis(500)).ok().and_then(|s| s.lines().last().map(String::from));
                let _ = std::fs::remove_file(path);
                Err(CaptureError::Other(detail.filter(|d| !d.is_empty()).unwrap_or_else(|| "no sound from the microphone".into())))
            }
        }
    }

    /// Ends ffmpeg cleanly ('q', so the file gets its index), or kills it.
    fn end(&mut self) {
        if let Some(mut stdin) = self.stdin.take() {
            let _ = stdin.write_all(b"q");
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if let Ok(Some(_)) = self.child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        log::error!("voice: ffmpeg didn't stop; killing it");
        let _ = self.child.kill();
        let _ = self.child.wait();
    }

    /// Stops and returns the file, if anything was written.
    pub fn stop(mut self) -> Option<PathBuf> {
        self.end();
        let f = std::mem::take(&mut self.file);
        std::fs::metadata(&f).map(|m| m.len() > 0).unwrap_or(false).then_some(f)
    }
}

impl Drop for VoiceRec {
    fn drop(&mut self) {
        if self.stdin.is_some() {
            self.end();
        }
    }
}
