//! Where words may go on a canvas (`Sources/MonetShotKit/Model/SafeArea.swift`).
//! A stand-in until the vertical work lands with its own: the whole canvas
//! inset by 6%. Canvas pixels, top-left origin.

use crate::plan::Rect;

pub fn safe_area(canvas_width: f64, canvas_height: f64) -> Rect {
    Rect::new(canvas_width * 0.06, canvas_height * 0.06, canvas_width * 0.88, canvas_height * 0.88)
}
