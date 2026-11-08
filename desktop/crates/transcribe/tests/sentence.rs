//! A real voice through whisper, end to end: the sentence the Mac's `say`
//! spoke (`shared/fixtures/voice/sentence.m4a`) as a take's voice, heard
//! word by word, then captions on that take's export and its subtitles.
//! Downloads the model (57 MB) unless MONETSHOT_WHISPER_MODEL points at it,
//! so it runs only with MONETSHOT_WHISPER_TEST=1 (CI sets it). Set
//! MONETSHOT_RENDER_OUT=<dir> to keep the captioned frames, video and .srt.

use monetshot_core::project::Project;
use monetshot_core::{EditDoc, IsoDate, RecordingMeta};
use monetshot_transcribe as tr;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

#[test]
fn word_error_rate_counts_words() {
    assert_eq!(tr::word_error_rate("Hello there, world.", "hello there world"), 0.0);
    assert!((tr::word_error_rate("a b c d", "a x c") - 0.5).abs() < 1e-9);
}

#[test]
fn hears_the_sentence_and_captions_it() {
    if std::env::var_os("MONETSHOT_WHISPER_TEST").is_none() {
        eprintln!("skipped: set MONETSHOT_WHISPER_TEST=1 (downloads the speech model)");
        return;
    }
    let voice = repo().join("shared/fixtures/voice/sentence.m4a");
    let expected = std::fs::read_to_string(repo().join("shared/fixtures/voice/sentence.txt")).unwrap();
    let progress: tr::Progress = Arc::new(|s: tr::Stage| eprintln!("{s:?}"));
    let cancel = Arc::new(AtomicBool::new(false));
    let t0 = std::time::Instant::now();
    let model = tr::ensure_model(&progress, &cancel).expect("model");
    assert_eq!(tr::sha256_file(&model).unwrap(), tr::MODEL.sha256);
    eprintln!("model ready in {:.1}s", t0.elapsed().as_secs_f64());

    // A take: a test card video with the sentence as its voice, 0.5 s in.
    let out = std::env::var_os("MONETSHOT_RENDER_OUT").map(PathBuf::from).unwrap_or_else(|| std::env::temp_dir().join("monetshot-whisper-test"));
    let folder = out.join("voice-test.reel");
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();
    let ffmpeg = monetshot_export::ffmpeg::tools().expect("ffmpeg").ffmpeg.clone();
    let ok = std::process::Command::new(&ffmpeg)
        .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-t", "7", "-pix_fmt", "yuv420p", "-c:v", "libx264"])
        .arg(folder.join("screen.mp4"))
        .status()
        .unwrap();
    assert!(ok.success(), "test video");
    std::fs::copy(&voice, folder.join("voice.m4a")).unwrap();
    let mut meta = RecordingMeta::new(1280, 720, 1.0, 7.0, IsoDate::now(), "display", "screen.mp4");
    meta.voice = Some("voice.m4a".into());
    meta.voice_offset = Some(0.5);
    let mut edit = EditDoc::default();
    edit.captions = Some(true);
    edit.output_width = 1280;
    let project = Project::new(folder.clone(), meta, Default::default(), edit);
    project.save_meta().unwrap();
    project.save_cursor().unwrap();
    project.save_edit().unwrap();
    let project = Project::load(&folder).unwrap();

    let t1 = std::time::Instant::now();
    let t = tr::transcribe_take(&project.takes[0], None, &progress, cancel).expect("transcribe");
    let heard: Vec<&str> = t.words.iter().map(|w| w.text.as_str()).collect();
    let wer = tr::word_error_rate(&expected, &heard.join(" "));
    eprintln!("heard in {:.1}s ({:?}): {}", t1.elapsed().as_secs_f64(), t.language, heard.join(" "));
    for w in &t.words {
        eprintln!("  {:6.2} {:6.2} {}", w.start, w.end, w.text);
    }
    eprintln!("word error rate {wer:.3}");
    // base.en hears the made-up name "Monet Shot" as one word ("Monashot",
    // two errors) and "polished" as "polish" (Apple's recogniser does too):
    // 3/16. No prompt is fed to whisper to game this; a real-world miss
    // beyond those three fails.
    assert!(wer <= 0.2, "word error rate {wer}");
    assert_eq!(t.language.as_deref(), Some("en"));
    // Times are the take's: the voice starts 0.5 s in, the sentence ~5.8 s long.
    assert!(t.words[0].start >= 0.45 && t.words[0].start < 1.2, "first word at {}", t.words[0].start);
    assert!(t.words.last().unwrap().end < 7.0);
    assert!(t.words.windows(2).all(|p| p[0].start <= p[1].start));
    let saved = monetshot_core::Transcript::load(&folder).expect("transcript.json");
    assert_eq!(saved.words.len(), t.words.len());

    // Captions over the export, and its subtitles.
    let project = Project::load(&folder).unwrap();
    let srt = monetshot_export::subtitles::srt(&project).expect("subtitles");
    eprintln!("{srt}");
    assert!(srt.starts_with("1\n00:00:00,"), "srt {srt}");
    let mid = (t.words[2].start + t.words[2].end) / 2.0;
    let still = monetshot_export::render_still(&project, mid, None).unwrap();
    let png = monetshot_export::export::png(&still).unwrap();
    std::fs::write(out.join("captioned-frame.png"), png).unwrap();
    let video = out.join("voice-test.mp4");
    let cancel = AtomicBool::new(false);
    monetshot_export::export(&project, &video, &|_: f64| {}, &cancel).expect("export");
    let written = monetshot_export::subtitles::write_srt(&project, &video).unwrap().expect("srt beside the video");
    assert_eq!(std::fs::read_to_string(written).unwrap(), srt);
    let probe = monetshot_export::probe(&video).unwrap();
    assert!(probe.has_audio, "the voice is in the export");
    assert!((probe.duration - 7.0).abs() < 0.2, "length {}", probe.duration);
    eprintln!("wrote {}", out.display());
}
