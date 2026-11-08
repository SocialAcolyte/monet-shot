//! The editor's camera and music (owner: ms-capture). Commands listed in
//! docs/porting/contracts/ipc.md, "Editor media". Ports the camera and music
//! parts of the Mac's EditorModel, CameraRecorder and MusicCatalog.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use monetshot_core as core;
use serde::Serialize;
use tauri::{AppHandle, Manager};

use crate::{camera, log};

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

// MARK: camera

/// Turns the camera on for this editor (its window label owns the hold).
#[tauri::command]
pub async fn camera_open(owner: String) -> bool {
    tauri::async_runtime::spawn_blocking(move || camera::acquire(&owner)).await.unwrap_or(false)
}

#[tauri::command]
pub fn camera_close(owner: String) {
    camera::release(&owner)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Devices {
    cameras: Vec<Device>,
    microphones: Vec<Device>,
    /// The remembered choice; null = the system default.
    camera: Option<String>,
    mic: Option<String>,
}

#[derive(Serialize)]
pub struct Device {
    id: String,
    name: String,
}

#[tauri::command]
pub async fn camera_devices() -> Result<Devices, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let d = |v: Vec<monetshot_capture::Device>| v.into_iter().map(|x| Device { id: x.id, name: x.name }).collect();
        let c = camera::choice();
        Ok(Devices {
            cameras: d(monetshot_capture::cameras().map_err(err)?),
            microphones: d(monetshot_capture::microphones().unwrap_or_default()),
            camera: c.camera,
            mic: c.mic,
        })
    })
    .await
    .map_err(err)?
}

#[tauri::command]
pub async fn camera_use(camera: Option<String>, mic: Option<String>) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || camera::use_device(camera, mic)).await.map_err(err)?
}

/// Starts `<folder>/<file>`; returns once its first frame is in (so the
/// edit can start playing in step with it).
#[tauri::command]
pub async fn camera_record(folder: String, file: String) -> Result<(), String> {
    let path = Path::new(&folder).join(&file);
    tauri::async_runtime::spawn_blocking(move || camera::record(&path).map(|_| ())).await.map_err(err)?
}

#[derive(Serialize)]
pub struct Recorded {
    /// File name inside the folder.
    file: String,
    duration: f64,
}

/// Stops the file: its name and length, or null if nothing usable was written.
#[tauri::command]
pub async fn camera_stop() -> Result<Option<Recorded>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let Some(path) = camera::stop() else { return Ok(None) };
        let duration = monetshot_capture::ffmpeg().ok().and_then(|f| f.duration(&path)).unwrap_or(0.0);
        let file = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
        Ok(Some(Recorded { file, duration }))
    })
    .await
    .map_err(err)?
}

/// "Just me": the camera file `<folder>/<file>` becomes a new take of the
/// recording (as the Mac's Imports.video), moved into take-N/. The page then
/// calls store.takesAdded({zooms: false}).
#[tauri::command]
pub async fn camera_take(folder: String, file: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || import_take(Path::new(&folder), &Path::new(&folder).join(&file))).await.map_err(err)?
}

/// A video file into `project` as its next take (source "import": no cursor log).
pub fn import_take(project: &Path, video: &Path) -> Result<(), String> {
    let (w, h, duration) = probe(video)?;
    let p = core::Project::load(project).map_err(err)?;
    let folder = p.next_take_folder();
    std::fs::create_dir_all(&folder).map_err(err)?;
    let ext = video.extension().and_then(|e| e.to_str()).unwrap_or("mp4").to_lowercase();
    let name = format!("screen.{ext}");
    let dest = folder.join(&name);
    if std::fs::rename(video, &dest).is_err() {
        std::fs::copy(video, &dest).map_err(err)?;
        let _ = std::fs::remove_file(video);
    }
    // Assume a Retina-like scale, as the Mac does; it only sizes a cursor an import never draws.
    let meta = core::RecordingMeta::new(w, h, 2.0, duration, core::IsoDate::now(), "import", &name);
    core::Take::new(folder.clone(), meta, core::CursorTrack::default()).save().map_err(err)?;
    log::info(&format!("camera clip added as {}: {duration:.1}s", folder.display()));
    Ok(())
}

/// Width, height (rotation applied) and duration of a video, by ffprobe.
fn probe(video: &Path) -> Result<(i64, i64, f64), String> {
    let ff = monetshot_capture::ffmpeg().map_err(err)?;
    let out = Command::new(&ff.ffprobe)
        .args(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:stream_side_data=rotation:format=duration", "-of", "json"])
        .arg(video)
        .stdin(Stdio::null())
        .output()
        .map_err(err)?;
    let j: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(err)?;
    let s = &j["streams"][0];
    let (mut w, mut h) = (s["width"].as_i64().unwrap_or(0), s["height"].as_i64().unwrap_or(0));
    let rot = s["side_data_list"][0]["rotation"].as_f64().unwrap_or(0.0).abs() as i64;
    if rot % 180 == 90 {
        std::mem::swap(&mut w, &mut h);
    }
    let d: f64 = j["format"]["duration"].as_str().and_then(|d| d.parse().ok()).unwrap_or(0.0);
    if w <= 0 || h <= 0 || d <= 0.0 {
        return Err(format!("{} has no video", video.display()));
    }
    Ok((w, h, d))
}

// MARK: media over loopback HTTP

/// A URL the webview's media player can stream `path` from. On Linux,
/// WebKitGTK's GStreamer player fails on Tauri's asset:// scheme
/// (FormatError, and 403 under hidden folders such as ~/.cache), but plays
/// the same files over HTTP with ranges, HEVC included. So videos and audio
/// are served by a tiny server on 127.0.0.1, hardened as a local file server
/// must be:
/// - a random port; only files registered here, each under its own token of
///   244 random bits (two UUID v4s, from the OS's random source);
/// - tokens belong to the window that asked and are revoked when it closes
///   (`release`), or by `media_release`;
/// - the request must name exactly `/<token>/<file name>`, no query;
/// - Host must be `127.0.0.1:<port>` (defeats DNS rebinding);
/// - CORS only for the app's own origins (and the dev server in debug
///   builds); any other Origin is refused. Range is supported, so WebGL can
///   upload frames from a `<video crossOrigin="anonymous">`.
#[tauri::command]
pub fn media_url(webview: tauri::Webview, path: String) -> Result<String, String> {
    register(webview.label(), Path::new(&path))
}

/// Revokes the tokens a page holds (it calls this when it's done with them).
#[tauri::command]
pub fn media_release(webview: tauri::Webview) {
    release(webview.label())
}

/// Revokes every token `owner` (a window label) holds: call when the window is destroyed.
pub fn release(owner: &str) {
    if let Some(s) = SERVER.get() {
        s.files.lock().unwrap().retain(|_, f| f.owner != owner);
    }
}

struct Registered {
    path: PathBuf,
    /// The file name as it appears in the URL (percent-encoded).
    name: String,
    owner: String,
}

struct MediaServer {
    port: u16,
    files: std::sync::Mutex<std::collections::HashMap<String, Registered>>,
}

static SERVER: std::sync::OnceLock<MediaServer> = std::sync::OnceLock::new();

/// The page origins that may read media (Origin header). Linux and macOS use
/// tauri://localhost; Windows http(s)://tauri.localhost; debug builds also
/// the Vite dev server.
fn allowed_origin(origin: &str) -> bool {
    matches!(origin, "tauri://localhost" | "http://tauri.localhost" | "https://tauri.localhost")
        || (cfg!(debug_assertions) && (origin == "http://localhost:5183" || origin == "http://127.0.0.1:5183"))
}

fn register(owner: &str, p: &Path) -> Result<String, String> {
    if !p.is_file() {
        return Err(format!("{} isn't a file", p.display()));
    }
    let server = media_server().map_err(err)?;
    let mut files = server.files.lock().unwrap();
    let existing = files.iter().find(|(_, f)| f.path == p && f.owner == owner).map(|(t, f)| (t.clone(), f.name.clone()));
    let (token, name) = existing.unwrap_or_else(|| {
        let token = random_token();
        let name = percent_encode(p.file_name().and_then(|n| n.to_str()).unwrap_or("media"));
        files.insert(token.clone(), Registered { path: p.to_path_buf(), name: name.clone(), owner: owner.to_string() });
        (token, name)
    });
    Ok(format!("http://127.0.0.1:{}/{token}/{name}", server.port))
}

fn media_server() -> std::io::Result<&'static MediaServer> {
    static START: std::sync::Mutex<()> = std::sync::Mutex::new(());
    if let Some(s) = SERVER.get() {
        return Ok(s);
    }
    let _one = START.lock().unwrap();
    if let Some(s) = SERVER.get() {
        return Ok(s);
    }
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    let server = SERVER.get_or_init(|| MediaServer { port, files: Default::default() });
    std::thread::Builder::new().name("monetshot-media".into()).spawn(move || {
        for conn in listener.incoming().flatten() {
            std::thread::spawn(move || {
                if let Err(e) = serve(conn, server) {
                    if !matches!(e.kind(), std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::WouldBlock) {
                        log::error(&format!("media server: {e}"));
                    }
                }
            });
        }
    })?;
    log::info(&format!("media server on 127.0.0.1:{port}"));
    Ok(server)
}

/// 244 bits from the OS's random source (two UUID v4s), as 64 hex digits.
fn random_token() -> String {
    format!("{}{}", core::new_id(), core::new_id()).replace('-', "").to_lowercase()
}

fn percent_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn content_type(p: &Path) -> &'static str {
    match p.extension().and_then(|e| e.to_str()).map(str::to_lowercase).as_deref() {
        Some("mp4" | "m4v") => "video/mp4",
        Some("mov") => "video/quicktime",
        Some("webm") => "video/webm",
        Some("mkv") => "video/x-matroska",
        Some("m4a") => "audio/mp4",
        Some("mp3") => "audio/mpeg",
        Some("wav") => "audio/wav",
        Some("flac") => "audio/flac",
        Some("ogg" | "opus") => "audio/ogg",
        Some("aac") => "audio/aac",
        _ => "application/octet-stream",
    }
}

/// One request: GET/HEAD (or a CORS preflight) of exactly /<token>/<name>.
fn serve(mut conn: std::net::TcpStream, server: &MediaServer) -> std::io::Result<()> {
    use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
    conn.set_read_timeout(Some(std::time::Duration::from_secs(30)))?;
    let mut reader = BufReader::new(conn.try_clone()?.take(16 * 1024));
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let mut parts = line.split_whitespace();
    let (method, target) = (parts.next().unwrap_or("").to_string(), parts.next().unwrap_or("").to_string());
    let (mut range, mut host, mut origin) = (None::<String>, None::<String>, None::<String>);
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h)? == 0 || h == "\r\n" || h == "\n" {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            let v = v.trim().to_string();
            match k.trim().to_ascii_lowercase().as_str() {
                "range" => range = Some(v),
                "host" => host = Some(v),
                "origin" => origin = Some(v),
                _ => {}
            }
        }
    }
    let refuse = |conn: &mut std::net::TcpStream, status: &str| write!(conn, "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    // DNS rebinding: a page on some other name that resolves here doesn't get in.
    if host.as_deref() != Some(&format!("127.0.0.1:{}", server.port)) {
        return refuse(&mut conn, "421 Misdirected Request");
    }
    // Only the app's pages; no Origin is a same-origin or non-browser request (the token still guards it).
    let cors = match origin.as_deref() {
        Some(o) if allowed_origin(o) => format!("Access-Control-Allow-Origin: {o}\r\nVary: Origin\r\nAccess-Control-Expose-Headers: Content-Range, Accept-Ranges, Content-Length\r\n"),
        Some(_) => return refuse(&mut conn, "403 Forbidden"),
        None => String::new(),
    };
    if method == "OPTIONS" {
        return write!(conn, "HTTP/1.1 204 No Content\r\n{cors}Access-Control-Allow-Methods: GET, HEAD\r\nAccess-Control-Allow-Headers: Range\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    }
    if method != "GET" && method != "HEAD" {
        return refuse(&mut conn, "405 Method Not Allowed");
    }
    // Exactly /<token>/<name>: no query, no other segments.
    let mut seg = target.strip_prefix('/').unwrap_or("").splitn(3, '/');
    let (token, name, extra) = (seg.next().unwrap_or(""), seg.next().unwrap_or(""), seg.next());
    let path = {
        let files = server.files.lock().unwrap();
        files.get(token).filter(|f| extra.is_none() && f.name == name && !target.contains('?')).map(|f| f.path.clone())
    };
    let Some(path) = path else { return refuse(&mut conn, "404 Not Found") };
    let mut file = std::fs::File::open(&path)?;
    let size = file.metadata()?.len();
    let (status, start, end) = match range.as_deref().map(|r| parse_range(r, size)) {
        Some(Some((s, e))) => ("206 Partial Content", s, e),
        Some(None) => {
            return write!(conn, "HTTP/1.1 416 Range Not Satisfiable\r\n{cors}Content-Range: bytes */{size}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }
        None => ("200 OK", 0, size.saturating_sub(1)),
    };
    let len = if size == 0 { 0 } else { end - start + 1 };
    let mut head = format!(
        "HTTP/1.1 {status}\r\n{cors}Content-Type: {}\r\nAccept-Ranges: bytes\r\nContent-Length: {len}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n",
        content_type(&path)
    );
    if status.starts_with("206") {
        head.push_str(&format!("Content-Range: bytes {start}-{end}/{size}\r\n"));
    }
    head.push_str("\r\n");
    conn.write_all(head.as_bytes())?;
    if method == "HEAD" {
        return Ok(());
    }
    file.seek(SeekFrom::Start(start))?;
    std::io::copy(&mut file.take(len), &mut conn)?;
    conn.flush()
}

/// "bytes=a-b" / "bytes=a-" / "bytes=-n" (the last n bytes) of a file of
/// `size`: the inclusive byte span, or None if it can't be satisfied.
fn parse_range(v: &str, size: u64) -> Option<(u64, u64)> {
    let r = v.strip_prefix("bytes=")?;
    let (a, b) = r.split_once('-')?;
    if size == 0 || r.contains(',') {
        return None;
    }
    let (start, end) = match (a.trim(), b.trim()) {
        ("", n) => (size.saturating_sub(n.parse::<u64>().ok()?.max(1)), size - 1),
        (a, "") => (a.parse().ok()?, size - 1),
        (a, b) => (a.parse().ok()?, b.parse::<u64>().ok()?.min(size - 1)),
    };
    (start <= end && start < size).then_some((start, end))
}

// MARK: preview proxies

/// A copy of a take's video that this computer's webview can play, for the
/// preview only: H.264 MP4, at most 1920 wide, same frames and times. Made
/// once with ffmpeg and kept in the app's cache; the .reel is never changed,
/// and export reads the original. Needed for takes made on a Mac (HEVC .mov)
/// where WebView2 lacks the HEVC extension (Windows) or GStreamer lacks
/// gst-libav (Linux). Returns the proxy's path.
#[tauri::command]
pub async fn video_proxy(app: AppHandle, path: String) -> Result<String, String> {
    let cache = app.path().app_cache_dir().map_err(err)?.join("proxies");
    tauri::async_runtime::spawn_blocking(move || make_proxy(Path::new(&path), &cache).map(|p| p.display().to_string()))
        .await
        .map_err(err)?
}

/// One proxy at a time: two editors asking for the same take wait for the first.
static PROXYING: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn make_proxy(src: &Path, cache: &Path) -> Result<PathBuf, String> {
    let _one = PROXYING.lock().unwrap_or_else(|e| e.into_inner());
    let m = std::fs::metadata(src).map_err(err)?;
    let stamp = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let key = core::music::stable_id(&format!("{}|{}|{stamp}", src.display(), m.len()));
    let out = cache.join(format!("{key}.mp4"));
    if out.is_file() {
        return Ok(out);
    }
    std::fs::create_dir_all(cache).map_err(err)?;
    let ff = monetshot_capture::ffmpeg().map_err(err)?;
    let enc = ff.best_encoder();
    let tmp = cache.join(format!("{key}.part.mp4"));
    let status = Command::new(&ff.ffmpeg)
        .args(["-hide_banner", "-loglevel", "error", "-nostdin", "-y"])
        .args(enc.input_args())
        .arg("-i")
        .arg(src)
        .args(["-map", "0:v:0", "-vf", "scale='min(1920,iw)':-2", "-fps_mode", "passthrough"])
        .args(enc.args(60))
        .args(["-an", "-movflags", "+faststart"])
        .arg(&tmp)
        .stdin(Stdio::null())
        .status()
        .map_err(err)?;
    if !status.success() {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("couldn't convert {} for the preview", src.display()));
    }
    std::fs::rename(&tmp, &out).map_err(err)?;
    log::info(&format!("preview proxy for {}: {}", src.display(), out.display()));
    Ok(out)
}

// MARK: music

/// The app's Music folder (Resources/Music, bundled), or the repo's in a dev run.
fn music_folder(app: &AppHandle) -> Option<PathBuf> {
    let bundled = app.path().resource_dir().ok().map(|r| r.join("Music"));
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/Music");
    [bundled, Some(repo)].into_iter().flatten().find(|f| f.join("library.json").is_file())
}

fn library(app: &AppHandle) -> Result<Vec<core::music::Song>, String> {
    static LOADED: std::sync::OnceLock<Vec<core::music::Song>> = std::sync::OnceLock::new();
    if let Some(l) = LOADED.get() {
        return Ok(l.clone());
    }
    let folder = music_folder(app).ok_or("the music library isn't installed")?;
    let songs = core::music::parse_library(&std::fs::read(folder.join("library.json")).map_err(err)?, &folder).map_err(err)?;
    Ok(LOADED.get_or_init(|| songs).clone())
}

/// Search words (all must match), or a mood's feel; neither = everything.
#[tauri::command]
pub fn music_library(app: AppHandle, query: String, mood: Option<String>) -> Result<Vec<core::music::Song>, String> {
    let songs = library(&app)?;
    Ok(core::music::search(&songs, &query, if query.trim().is_empty() { mood.as_deref() } else { None }).into_iter().cloned().collect())
}

/// A music file of your own, as a song (the page shows a file dialog first).
#[tauri::command]
pub async fn music_own_file(path: String) -> Result<core::music::Song, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let p = PathBuf::from(&path);
        let d = monetshot_capture::ffmpeg().ok().and_then(|f| f.duration(&p)).ok_or("that isn't an audio file")?;
        Ok(core::music::Song::own_file(&p, d))
    })
    .await
    .map_err(err)?
}

/// Copies the song into the recording (so exports work offline) and returns
/// its file name there. The page then sets edit.music and removes the old file.
#[tauri::command]
pub async fn music_add(folder: String, song: core::music::Song) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let src = file_path(&song.audio_url).ok_or("that track isn't on this computer")?;
        let ext = src.extension().and_then(|e| e.to_str()).map(str::to_lowercase).unwrap_or_else(|| "m4a".into());
        let name = core::music::local_file_name(&song, &ext);
        let dest = Path::new(&folder).join(&name);
        let _ = std::fs::remove_file(&dest);
        std::fs::copy(&src, &dest).map_err(err)?;
        log::info(&format!("music: {} by {} ({})", song.title, song.artist, song.license_label()));
        Ok(name)
    })
    .await
    .map_err(err)?
}

/// file:// URL (as library.json songs carry after parsing) or a plain path.
fn file_path(url: &str) -> Option<PathBuf> {
    let p = url.strip_prefix("file://").map(percent_decode).unwrap_or_else(|| url.to_string());
    // file:///C:/a/b (core's file_url on Windows): the path is C:/a/b.
    let b = p.as_bytes();
    let p = if b.len() > 2 && b[0] == b'/' && b[1].is_ascii_alphabetic() && b[2] == b':' { p[1..].to_string() } else { p };
    let p = PathBuf::from(p);
    p.is_file().then_some(p)
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[derive(Serialize)]
pub struct Shape {
    /// Peak levels 0...1 in 240 slices, for the snippet window.
    wave: Vec<f32>,
    /// The beat (bar length, first downbeat, lifts), if it has a steady one.
    grid: Option<core::music::MusicGrid>,
}

/// Waveform and beat grid of `<folder>/<file>`, read locally (one decode).
#[tauri::command]
pub async fn music_shape(folder: String, file: String) -> Result<Shape, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let samples = decode_mono(&Path::new(&folder).join(&file), 11_025)?;
        Ok(Shape { wave: peaks(&samples, 240), grid: core::music::MusicGrid::analyze(&samples, 11_025.0) })
    })
    .await
    .map_err(err)?
}

/// Mono f32 samples at `rate` Hz, by ffmpeg.
fn decode_mono(file: &Path, rate: u32) -> Result<Vec<f32>, String> {
    let ff = monetshot_capture::ffmpeg().map_err(err)?;
    let out = Command::new(&ff.ffmpeg)
        .args(["-hide_banner", "-loglevel", "error", "-nostdin", "-i"])
        .arg(file)
        .args(["-vn", "-ac", "1", "-ar", &rate.to_string(), "-f", "f32le", "-"])
        .stdin(Stdio::null())
        .output()
        .map_err(err)?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(out.stdout.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect())
}

/// Peak level per slice, scaled so the loudest is 1 (as MusicCatalog.waveform).
fn peaks(samples: &[f32], buckets: usize) -> Vec<f32> {
    if samples.is_empty() {
        return Vec::new();
    }
    let per = (samples.len() / buckets).max(1);
    let mut p = vec![0f32; buckets];
    for (i, s) in samples.iter().enumerate() {
        let b = (i / per).min(buckets - 1);
        p[b] = p[b].max(s.abs());
    }
    let top = p.iter().cloned().fold(0.01f32, f32::max);
    p.iter().map(|v| v / top).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peaks_normalise() {
        let s: Vec<f32> = (0..1000).map(|i| if i < 500 { 0.1 } else { -0.5 }).collect();
        let p = peaks(&s, 4);
        assert_eq!(p.len(), 4);
        assert!((p[0] - 0.2).abs() < 1e-6 && (p[3] - 1.0).abs() < 1e-6);
    }

    /// A real song from Resources/Music: decodes, gives a full waveform and,
    /// for a steady track, a beat grid. Skipped without ffmpeg or the library.
    #[test]
    fn shapes_a_library_song() {
        let folder = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/Music");
        let Ok(data) = std::fs::read(folder.join("library.json")) else { return };
        if monetshot_capture::ffmpeg().is_err() {
            return;
        }
        let songs = core::music::parse_library(&data, &folder).unwrap();
        let song = songs.first().expect("a song");
        let path = file_path(&song.audio_url).expect("file url resolves");
        let samples = decode_mono(&path, 11_025).unwrap();
        assert!((samples.len() as f64 / 11_025.0 - song.duration).abs() < 1.5, "length {} vs {}", samples.len() as f64 / 11_025.0, song.duration);
        let wave = peaks(&samples, 240);
        assert_eq!(wave.len(), 240);
        assert!(wave.iter().any(|&v| v == 1.0));
        let grid = core::music::MusicGrid::analyze(&samples, 11_025.0);
        eprintln!("{} by {}: grid {:?}", song.title, song.artist, grid.as_ref().map(|g| (g.bpm(), g.lifts.len())));
    }

    /// An HEVC take (as the Mac records) gets an H.264 proxy of the same
    /// length, made once. Skipped without ffmpeg/libx265.
    #[test]
    fn proxies_hevc() {
        let Ok(ff) = monetshot_capture::ffmpeg() else { return };
        let dir = std::env::temp_dir().join(format!("ms-proxy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("screen.mov");
        let ok = Command::new(&ff.ffmpeg)
            .args(["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=60:d=2", "-c:v", "libx265", "-tag:v", "hvc1"])
            .arg(&src)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            return;
        }
        let p = make_proxy(&src, &dir.join("cache")).unwrap();
        let probe = Command::new(&ff.ffprobe).args(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0"]).arg(&p).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&probe.stdout).trim(), "h264");
        assert!((ff.duration(&p).unwrap() - 2.0).abs() < 0.1);
        assert_eq!(make_proxy(&src, &dir.join("cache")).unwrap(), p); // cached
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ranges() {
        assert_eq!(parse_range("bytes=0-99", 1000), Some((0, 99)));
        assert_eq!(parse_range("bytes=900-", 1000), Some((900, 999)));
        assert_eq!(parse_range("bytes=-100", 1000), Some((900, 999)));
        assert_eq!(parse_range("bytes=990-5000", 1000), Some((990, 999)));
        assert_eq!(parse_range("bytes=1000-", 1000), None);
        assert_eq!(parse_range("bytes=0-1,5-9", 1000), None);
    }

    /// Raw request to the media server; returns the whole response.
    fn request(port: u16, target: &str, headers: &[(&str, &str)]) -> Vec<u8> {
        use std::io::{Read, Write};
        let mut c = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        let mut req = format!("GET {target} HTTP/1.1\r\n");
        for (k, v) in headers {
            req.push_str(&format!("{k}: {v}\r\n"));
        }
        req.push_str("\r\n");
        c.write_all(req.as_bytes()).unwrap();
        let mut out = Vec::new();
        // Windows may reset the socket once a refusal is sent: keep what came.
        let _ = c.read_to_end(&mut out);
        out
    }

    fn media_fixture(name: &str) -> (PathBuf, u16, String) {
        let dir = std::env::temp_dir().join(format!("ms-media-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("a b.mp4");
        std::fs::write(&f, (0..=255u8).cycle().take(5000).collect::<Vec<u8>>()).unwrap();
        let url = register(name, &f).unwrap();
        let rest = url.strip_prefix("http://127.0.0.1:").unwrap();
        let (port, path) = rest.split_once('/').unwrap();
        (dir, port.parse().unwrap(), format!("/{path}"))
    }

    /// Only registered files, ranges right, CORS only for the app.
    #[test]
    fn serves_registered_files_with_ranges() {
        let (dir, port, path) = media_fixture("w1");
        let host = format!("127.0.0.1:{port}");
        let full = request(port, &path, &[("Host", &host), ("Origin", "tauri://localhost")]);
        let text = String::from_utf8_lossy(&full);
        assert!(text.starts_with("HTTP/1.1 200"), "{text}");
        assert!(text.contains("Content-Length: 5000") && text.contains("Access-Control-Allow-Origin: tauri://localhost"));
        let part = request(port, &path, &[("Host", &host), ("Range", "bytes=10-19")]);
        let i = part.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
        assert!(String::from_utf8_lossy(&part[..i]).contains("Content-Range: bytes 10-19/5000"));
        assert!(!String::from_utf8_lossy(&part[..i]).contains("Access-Control-Allow-Origin"));
        assert_eq!(&part[i..], &(10..20).collect::<Vec<u8>>()[..]);
        // The token is long and the same file gets the same one for the same window.
        let token = path.split('/').nth(1).unwrap();
        assert_eq!(token.len(), 64);
        assert_eq!(register("w1", &dir.join("a b.mp4")).unwrap(), format!("http://127.0.0.1:{port}{path}"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Wrong Host (DNS rebinding), a foreign Origin, other paths, queries,
    /// and released tokens are all refused.
    #[test]
    fn refuses_what_it_should() {
        let (dir, port, path) = media_fixture("w2");
        let host = format!("127.0.0.1:{port}");
        let status = |r: Vec<u8>| String::from_utf8_lossy(&r).lines().next().unwrap_or("").to_string();
        assert!(status(request(port, &path, &[("Host", "evil.example:80")])).contains("421"));
        assert!(status(request(port, &path, &[])).contains("421"));
        assert!(status(request(port, &path, &[("Host", &host), ("Origin", "https://evil.example")])).contains("403"));
        assert!(status(request(port, &format!("{path}?x=1"), &[("Host", &host)])).contains("404"));
        assert!(status(request(port, &format!("{path}/../../etc/passwd"), &[("Host", &host)])).contains("404"));
        let token = path.split('/').nth(1).unwrap();
        assert!(status(request(port, &format!("/{token}/other.mp4"), &[("Host", &host)])).contains("404"));
        assert!(status(request(port, "/0000/a%20b.mp4", &[("Host", &host)])).contains("404"));
        // Another window's release leaves this one's token alone; its own revokes it.
        release("someone-else");
        assert!(status(request(port, &path, &[("Host", &host)])).contains("200"));
        release("w2");
        assert!(status(request(port, &path, &[("Host", &host)])).contains("404"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn decodes_file_urls() {
        assert_eq!(percent_decode("/a%20b/c%C3%A9.m4a"), "/a b/cé.m4a");
    }
}
