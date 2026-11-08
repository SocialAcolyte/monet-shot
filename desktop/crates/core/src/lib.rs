//! Monet Shot's brain, shared by the Linux and Windows app, its preview
//! (through core-wasm) and its export. A port of `Sources/MonetShotKit`;
//! `shared/fixtures` (generated from the Swift) keeps the two in step.

pub mod camera;
pub mod captions;
pub mod camera_math;
pub mod cursor;
pub mod formats;
pub mod json;
pub mod model;
pub mod music;
#[cfg(not(target_arch = "wasm32"))]
pub mod paths;
pub mod plan;
pub mod privacy;
pub mod project;
pub mod safe_area;
pub mod text;
pub mod timemap;

pub use captions::{Transcript, TranscriptWord};
pub use camera::{music_envelope, CameraClip, CameraCorner, CameraLook, CameraShape};
pub use camera_math::{auto_zooms, segment_edits, Camera, SmoothTrack};
pub use json::{to_swift_json, IsoDate};
pub use model::*;
pub use music::{MusicChoice, MusicGrid, Song};
pub use plan::{FramePlan, Planner};
pub use privacy::{BlurRegion, BlurStyle, NormRect, TakeCrop};
pub use project::{Project, Take};
pub use text::{text_edits, text_motion, TextAnimation, TextOverlay, TextState, TextStyle, TextTone};
pub use timemap::{clip_edits, TimeMap};
