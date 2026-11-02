//! Music files read locally: the waveform the snippet window draws and the
//! beat grid it snaps to (decoded with ffmpeg; the analysis is core's).

use crate::ffmpeg::{decode_audio, ExportError};
use monetshot_core::music::MusicGrid;
use std::path::Path;

/// Peak levels (0...1) in `buckets` slices, normalised to the loudest.
pub fn waveform(path: &Path, buckets: usize) -> Result<Vec<f32>, ExportError> {
    let s = decode_audio(path, 0.0, None, 1, 8000)?;
    if s.is_empty() || buckets == 0 {
        return Ok(vec![]);
    }
    let per = (s.len() / buckets).max(1);
    let mut peaks = vec![0f32; buckets];
    for (i, v) in s.iter().enumerate() {
        let b = (i / per).min(buckets - 1);
        peaks[b] = peaks[b].max(v.abs());
    }
    let top = peaks.iter().cloned().fold(0.01f32, f32::max);
    Ok(peaks.into_iter().map(|p| p / top).collect())
}

/// The song's beat grid (mono at 11025 Hz, as the Mac reads it); None if it
/// has no steady beat.
pub fn grid(path: &Path) -> Result<Option<MusicGrid>, ExportError> {
    let s = decode_audio(path, 0.0, None, 1, 11_025)?;
    Ok(MusicGrid::analyze(&s, 11_025.0))
}
