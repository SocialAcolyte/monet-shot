//! Monet Shot's export: draws `monetshot_core::FramePlan`s on the CPU (in
//! linear light, as CoreImage does on the Mac) and runs the ffmpeg pipeline:
//! export, stills/thumbnails, import, music waveform and beat grid.
//! `cursor_art` is always available (core-wasm uses it for the preview).

pub mod art;
pub mod text_art;
#[cfg(feature = "pipeline")]
pub mod export;
#[cfg(feature = "pipeline")]
pub mod ffmpeg;
#[cfg(feature = "pipeline")]
pub mod imports;
#[cfg(feature = "paint")]
pub mod paint;
#[cfg(feature = "pipeline")]
pub mod sound;
#[cfg(feature = "pipeline")]
pub mod subtitles;

pub use art::{cursor_art, CursorArt};
pub use text_art::{text_art, TextArt};
#[cfg(feature = "pipeline")]
pub use export::{default_output, export, render_still, thumb_is_fresh, thumb_time, write_thumb};
#[cfg(feature = "pipeline")]
pub use ffmpeg::{probe, ExportError, Probe};
#[cfg(feature = "paint")]
pub use paint::{Painter, Rgba8};
