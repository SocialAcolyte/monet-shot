//! The recordings folder, newest first (the Mac's `Library`).

use std::path::{Path, PathBuf};

pub fn recent(limit: usize) -> Vec<PathBuf> {
    let mut v = monetshot_core::project::list_recordings(&monetshot_core::paths::library_dir());
    v.truncate(limit);
    v
}

const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// "18 Oct, 14:02" from "2026-10-18 14.02.11.reel"; the bare name otherwise.
pub fn title(url: &Path) -> String {
    let name = url.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    parse(&name).unwrap_or(name)
}

fn parse(name: &str) -> Option<String> {
    let b = name.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || b[10] != b' ' || b[13] != b'.' || b[16] != b'.' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| name.get(r)?.parse::<u32>().ok();
    let (month, day, hour, minute) = (num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?);
    num(0..4)?;
    num(17..19)?;
    let m = MONTHS.get(month.checked_sub(1)? as usize)?;
    if day == 0 || day > 31 || hour > 23 || minute > 59 {
        return None;
    }
    Some(format!("{day} {m}, {hour:02}:{minute:02}"))
}

#[cfg(test)]
mod tests {
    use super::title;
    use std::path::Path;

    #[test]
    fn titles_like_the_mac() {
        assert_eq!(title(Path::new("/x/2026-10-18 14.02.11.reel")), "18 Oct, 14:02");
        assert_eq!(title(Path::new("/x/2026-01-03 09.05.00 2.reel")), "3 Jan, 09:05");
        assert_eq!(title(Path::new("/x/My video.reel")), "My video");
    }
}
