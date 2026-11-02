//! Finding ffmpeg, choosing an H.264 encoder, and the small commands every
//! backend shares. ffmpeg is the system package on Linux, a sidecar next to
//! the executable on Windows, Homebrew's on the dev Mac.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::CaptureError;

#[derive(Clone, Debug)]
pub struct Ffmpeg {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
    /// H.264 encoders this build has, best first among the ones we use.
    pub encoders: Vec<Encoder>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Encoder {
    Nvenc,
    Qsv,
    Amf,
    Vaapi,
    VideoToolbox,
    X264,
}

impl Encoder {
    pub fn name(self) -> &'static str {
        match self {
            Encoder::Nvenc => "h264_nvenc",
            Encoder::Qsv => "h264_qsv",
            Encoder::Amf => "h264_amf",
            Encoder::Vaapi => "h264_vaapi",
            Encoder::VideoToolbox => "h264_videotoolbox",
            Encoder::X264 => "libx264",
        }
    }

    /// Output options for a screen recording: high quality, fast enough for
    /// real time, every frame kept, yuv420p so every player opens it.
    pub fn args(self, fps: u32) -> Vec<String> {
        let gop = (fps * 2).to_string();
        let mut a: Vec<String> = match self {
            Encoder::Nvenc => vec!["-c:v", "h264_nvenc", "-preset", "p4", "-tune", "hq", "-rc", "vbr", "-cq", "19", "-b:v", "0"],
            Encoder::Qsv => vec!["-c:v", "h264_qsv", "-preset", "faster", "-global_quality", "20"],
            Encoder::Amf => vec!["-c:v", "h264_amf", "-quality", "speed", "-rc", "cqp", "-qp_i", "19", "-qp_p", "21"],
            Encoder::Vaapi => vec!["-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-qp", "20"],
            Encoder::VideoToolbox => vec!["-c:v", "h264_videotoolbox", "-q:v", "65", "-realtime", "1"],
            Encoder::X264 => vec!["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-tune", "zerolatency"],
        }
        .into_iter()
        .map(String::from)
        .collect();
        if self != Encoder::Vaapi {
            a.extend(["-pix_fmt", "yuv420p"].map(String::from));
        }
        a.extend(["-g", gop.as_str()].map(String::from));
        a
    }

    /// Hardware encoders need a device; options before `-i` for that.
    pub fn input_args(self) -> Vec<String> {
        match self {
            Encoder::Vaapi => ["-vaapi_device", &vaapi_device()].map(String::from).to_vec(),
            _ => Vec::new(),
        }
    }
}

fn vaapi_device() -> String {
    std::env::var("MONETSHOT_VAAPI_DEVICE").unwrap_or_else(|_| "/dev/dri/renderD128".into())
}

/// Locates ffmpeg + ffprobe and lists the encoders.
/// `MONETSHOT_FFMPEG` overrides (a path to the ffmpeg binary).
pub fn ffmpeg() -> Result<Ffmpeg, CaptureError> {
    let ffmpeg = locate("ffmpeg").ok_or_else(|| CaptureError::Ffmpeg(missing_hint()))?;
    // Its sibling: "ffmpeg.exe" -> "ffprobe.exe", "ffmpeg-x86_64-pc-windows-msvc.exe" -> "ffprobe-…".
    let name = ffmpeg.file_name().and_then(|n| n.to_str()).unwrap_or("ffmpeg").replacen("ffmpeg", "ffprobe", 1);
    let ffprobe = ffmpeg.with_file_name(name);
    let ffprobe = if ffprobe.exists() { ffprobe } else { locate("ffprobe").unwrap_or(ffprobe) };
    let out = Command::new(&ffmpeg)
        .args(["-hide_banner", "-encoders"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .no_window()
        .output()
        .map_err(|e| CaptureError::Ffmpeg(format!("could not run {}: {e}", ffmpeg.display())))?;
    let list = String::from_utf8_lossy(&out.stdout);
    let has = |n: &str| list.lines().any(|l| l.split_whitespace().nth(1) == Some(n));
    let order: &[Encoder] = if cfg!(target_os = "macos") {
        &[Encoder::VideoToolbox, Encoder::X264]
    } else if cfg!(windows) {
        &[Encoder::Nvenc, Encoder::Qsv, Encoder::Amf, Encoder::X264]
    } else {
        &[Encoder::Nvenc, Encoder::Vaapi, Encoder::Qsv, Encoder::X264]
    };
    let encoders = order.iter().copied().filter(|e| has(e.name())).collect();
    Ok(Ffmpeg { ffmpeg, ffprobe, encoders })
}

fn missing_hint() -> String {
    if cfg!(windows) {
        "ffmpeg.exe is missing next to Monet Shot; reinstall it".into()
    } else if cfg!(target_os = "linux") {
        "ffmpeg is not installed (Arch: pacman -S ffmpeg; Ubuntu: apt install ffmpeg)".into()
    } else {
        "ffmpeg is not installed (brew install ffmpeg)".into()
    }
}

fn exe(name: &str) -> String {
    if cfg!(windows) { format!("{name}.exe") } else { name.to_string() }
}

fn locate(name: &str) -> Option<PathBuf> {
    if name == "ffmpeg" {
        if let Some(p) = std::env::var_os("MONETSHOT_FFMPEG") {
            return Some(PathBuf::from(p));
        }
    }
    // The bundled sidecar (Windows; also an AppImage) sits next to us.
    if let Some(dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)) {
        let p = dir.join(exe(name));
        if p.is_file() {
            return Some(p);
        }
    }
    let path = std::env::var_os("PATH")?;
    let mut dirs: Vec<PathBuf> = std::env::split_paths(&path).collect();
    // A GUI app on macOS doesn't get the shell's PATH.
    if cfg!(target_os = "macos") {
        dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from));
    }
    dirs.into_iter().map(|d| d.join(exe(name))).find(|p| p.is_file())
}

impl Ffmpeg {
    /// The first encoder that actually works on this machine: a build can
    /// list h264_nvenc with no NVIDIA card in it. Probed once per process
    /// with one tiny frame; libx264 is the floor.
    pub fn best_encoder(&self) -> Encoder {
        static BEST: std::sync::OnceLock<Encoder> = std::sync::OnceLock::new();
        *BEST.get_or_init(|| {
            let e = self.encoders.iter().copied().find(|&e| e == Encoder::X264 || self.probe(e)).unwrap_or(Encoder::X264);
            log::info!("encoder: {}", e.name());
            e
        })
    }

    fn probe(&self, e: Encoder) -> bool {
        let mut c = self.command();
        c.args(e.input_args())
            .args(["-f", "lavfi", "-i", "color=c=black:s=256x144:r=30", "-frames:v", "2"])
            .args(e.args(30))
            .args(["-f", "null", "-"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        c.status().map(|s| s.success()).unwrap_or(false)
    }

    pub fn command(&self) -> Command {
        let mut c = Command::new(&self.ffmpeg);
        c.args(["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]).no_window();
        c
    }

    /// A video file's duration in seconds, read from its container.
    pub fn duration(&self, file: &Path) -> Option<f64> {
        let out = Command::new(&self.ffprobe)
            .args(["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1"])
            .arg(file)
            .stdin(Stdio::null())
            .no_window()
            .output()
            .ok()?;
        let d: f64 = String::from_utf8_lossy(&out.stdout).trim().parse().ok()?;
        (d.is_finite() && d > 0.0).then_some(d)
    }
}

/// Keeps a console window from flashing up for each child on Windows.
pub trait NoWindow {
    fn no_window(&mut self) -> &mut Self;
}

impl NoWindow for Command {
    #[cfg(windows)]
    fn no_window(&mut self) -> &mut Self {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        self.creation_flags(CREATE_NO_WINDOW)
    }
    #[cfg(not(windows))]
    fn no_window(&mut self) -> &mut Self {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn args_keep_yuv420p_and_faststart() {
        let a = Encoder::X264.args(60);
        assert!(a.windows(2).any(|w| w == ["-pix_fmt", "yuv420p"]));
        assert!(a.windows(2).any(|w| w == ["-g", "120"]));
        let v = Encoder::Vaapi.args(60);
        assert!(!v.iter().any(|s| s == "-pix_fmt"));
    }
}
