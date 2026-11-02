//! The cursor looks. The art itself is drawn by `monetshot-export`
//! (`cursor_art`), which the preview also uses through core-wasm.

use crate::model::string_enum;

string_enum!(
    /// How Monet Shot draws the pointer.
    CursorStyle, default Classic, {
        /// Black arrow, white rim.
        Classic = "classic",
        /// White arrow, dark rim.
        White = "white",
        /// A rounded, chunky arrow in a soft colour.
        Soft = "soft",
        /// A translucent dot.
        Dot = "dot",
        /// A soft arrow with a name tag.
        Tag = "tag",
    }
);

impl CursorStyle {
    pub fn label(&self) -> &str {
        match self.known() {
            CursorStyle::White => "White",
            CursorStyle::Soft => "Soft",
            CursorStyle::Dot => "Dot",
            CursorStyle::Tag => "Name tag",
            _ => "Classic",
        }
    }
    /// Styles that take a colour.
    pub fn tinted(&self) -> bool {
        matches!(self.known(), CursorStyle::Soft | CursorStyle::Dot | CursorStyle::Tag)
    }
}

string_enum!(
    /// The soft colours a cursor can wear.
    CursorTint, default Clay, {
        Clay = "clay", Sky = "sky", Mint = "mint", Butter = "butter", Lilac = "lilac", Rose = "rose",
    }
);

impl CursorTint {
    /// sRGB hex.
    pub fn hex(&self) -> u32 {
        match self.known() {
            CursorTint::Sky => 0x5F9FD8,
            CursorTint::Mint => 0x4FB38E,
            CursorTint::Butter => 0xE8B53E,
            CursorTint::Lilac => 0x9584DB,
            CursorTint::Rose => 0xE07C9E,
            _ => 0xE07A55,
        }
    }
}

/// Height of the arrow in screen points at 1x.
pub const POINT_HEIGHT: f64 = 22.0;
