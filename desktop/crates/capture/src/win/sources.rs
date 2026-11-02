//! Monitors and windows for Monet Shot's own picker, with thumbnails.

use ::windows::core::{BOOL, PWSTR};
use ::windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT};
use ::windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use ::windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, EnumDisplayMonitors, GetDC, GetDIBits,
    GetMonitorInfoW, ReleaseDC, SelectObject, SetStretchBltMode, StretchBlt, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
    DIB_RGB_COLORS, HALFTONE, HBITMAP, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW, SRCCOPY,
};
use ::windows::Win32::Storage::Xps::{PrintWindow, PRINT_WINDOW_FLAGS};
use ::windows::Win32::System::Threading::{
    GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use ::windows::Win32::UI::HiDpi::{GetDpiForMonitor, GetDpiForWindow, MDT_EFFECTIVE_DPI};
use ::windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetAncestor, GetWindowLongW, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsIconic,
    IsWindow, IsWindowVisible, GA_ROOTOWNER, GWL_EXSTYLE, WS_EX_TOOLWINDOW,
};

use super::Target;
use crate::pointer::Bar;
use crate::{CaptureError, Rect, Source, SourceId, SourceKind, Thumbnail};

const PW_RENDERFULLCONTENT: u32 = 2;

fn rect(r: RECT) -> Rect {
    Rect { x: r.left as f64, y: r.top as f64, width: (r.right - r.left) as f64, height: (r.bottom - r.top) as f64 }
}

struct Monitor {
    handle: HMONITOR,
    name: String,
    bounds: Rect,
    work: Rect,
    scale: f64,
    primary: bool,
}

fn monitors() -> Vec<Monitor> {
    unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let out = &mut *(data.0 as *mut Vec<Monitor>);
        let mut info = MONITORINFOEXW::default();
        info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        if GetMonitorInfoW(m, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO).as_bool() {
            let (mut dx, mut dy) = (96u32, 96u32);
            let _ = GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut dx, &mut dy);
            let n = info.szDevice.iter().position(|&c| c == 0).unwrap_or(info.szDevice.len());
            out.push(Monitor {
                handle: m,
                name: String::from_utf16_lossy(&info.szDevice[..n]),
                bounds: rect(info.monitorInfo.rcMonitor),
                work: rect(info.monitorInfo.rcWork),
                scale: dx as f64 / 96.0,
                primary: info.monitorInfo.dwFlags & 1 != 0,
            });
        }
        true.into()
    }
    let mut v: Vec<Monitor> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut v as *mut _ as isize));
    }
    // The primary first, then left to right.
    v.sort_by(|a, b| b.primary.cmp(&a.primary).then(a.bounds.x.total_cmp(&b.bounds.x)));
    v
}

struct Window {
    hwnd: HWND,
    title: String,
    app: Option<String>,
    bounds: Rect,
    scale: f64,
}

fn window_bounds(hwnd: HWND) -> Option<Rect> {
    let mut r = RECT::default();
    unsafe {
        DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut _ as *mut _, std::mem::size_of::<RECT>() as u32).ok()?;
    }
    Some(rect(r))
}

/// The window's current bounds, for following it while recording.
pub(crate) fn current_bounds(hwnd: HWND) -> Option<Rect> {
    unsafe { IsWindow(Some(hwnd)).as_bool() }.then(|| window_bounds(hwnd)).flatten()
}

fn process_name(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(h);
        if !ok {
            return None;
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        let file = path.rsplit('\\').next()?.to_string();
        Some(file.strip_suffix(".exe").unwrap_or(&file).to_string())
    }
}

/// Top-level windows a person would Alt-Tab to, ours left out.
fn windows() -> Vec<Window> {
    unsafe extern "system" fn each(hwnd: HWND, data: LPARAM) -> BOOL {
        let out = &mut *(data.0 as *mut Vec<Window>);
        if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() || GetWindowTextLengthW(hwnd) == 0 {
            return true.into();
        }
        if GetWindowLongW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0 || GetAncestor(hwnd, GA_ROOTOWNER) != hwnd {
            return true.into();
        }
        let mut cloaked = 0u32;
        let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut _, 4);
        if cloaked != 0 {
            return true.into();
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == GetCurrentProcessId() {
            return true.into();
        }
        let Some(bounds) = window_bounds(hwnd) else { return true.into() };
        if bounds.width < 40.0 || bounds.height < 40.0 {
            return true.into();
        }
        let mut buf = vec![0u16; GetWindowTextLengthW(hwnd) as usize + 1];
        let n = GetWindowTextW(hwnd, &mut buf);
        out.push(Window {
            hwnd,
            title: String::from_utf16_lossy(&buf[..n as usize]),
            app: process_name(pid),
            bounds,
            scale: GetDpiForWindow(hwnd) as f64 / 96.0,
        });
        true.into()
    }
    let mut v: Vec<Window> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(each), LPARAM(&mut v as *mut _ as isize));
    }
    v
}

pub(crate) fn list(thumbnails: bool) -> Result<Vec<Source>, CaptureError> {
    let mut out = Vec::new();
    for (i, m) in monitors().into_iter().enumerate() {
        out.push(Source {
            id: SourceId(format!("monitor:{}", m.name)),
            kind: SourceKind::Display,
            title: format!("Display {} ({}×{})", i + 1, m.bounds.width, m.bounds.height),
            app: None,
            bounds: m.bounds,
            scale: m.scale,
            thumbnail: if thumbnails { grab(None, m.bounds) } else { None },
        });
    }
    for w in windows() {
        out.push(Source {
            id: SourceId(format!("window:{}", w.hwnd.0 as isize)),
            kind: SourceKind::Window,
            title: w.title,
            app: w.app,
            bounds: w.bounds,
            scale: w.scale,
            thumbnail: if thumbnails { grab(Some(w.hwnd), w.bounds) } else { None },
        });
    }
    Ok(out)
}

pub(crate) fn resolve(id: &SourceId) -> Result<Target, CaptureError> {
    if let Some(name) = id.0.strip_prefix("monitor:") {
        let m = monitors().into_iter().find(|m| m.name == name).ok_or_else(|| CaptureError::Other("that display is gone".into()))?;
        return Ok(Target::Monitor { handle: m.handle.0 as isize, bounds: m.bounds, work: m.work, scale: m.scale });
    }
    if let Some(h) = id.0.strip_prefix("window:").and_then(|h| h.parse::<isize>().ok()) {
        let hwnd = HWND(h as *mut _);
        let bounds = current_bounds(hwnd).ok_or_else(|| CaptureError::Other("that window is gone".into()))?;
        let scale = unsafe { GetDpiForWindow(hwnd) } as f64 / 96.0;
        return Ok(Target::Window { hwnd: h, bounds, scale });
    }
    Err(CaptureError::Other(format!("unknown source {}", id.0)))
}

/// Where the hand goes to stop: the taskbar's edge (the monitor minus its
/// work area; the bottom if it auto-hides) and the record pill at the top.
pub(crate) fn stop_bars(bounds: Rect, work: Rect, scale: f64) -> Vec<Bar> {
    let (w, h) = (bounds.width.max(1.0), bounds.height.max(1.0));
    let pill = Bar::Top(56.0 * scale / h);
    let top = work.y - bounds.y;
    let left = work.x - bounds.x;
    let bottom = (bounds.y + bounds.height) - (work.y + work.height);
    let right = (bounds.x + bounds.width) - (work.x + work.width);
    let taskbar = if top > 0.0 {
        Bar::Top(top / h)
    } else if left > 0.0 {
        Bar::Left(left / w)
    } else if right > 0.0 {
        Bar::Right(right / w)
    } else if bottom > 0.0 {
        Bar::Bottom(bottom / h)
    } else {
        Bar::Bottom(48.0 * scale / h)
    };
    vec![taskbar, pill]
}

/// A ≤ 480 px wide PNG of the screen region (`hwnd` None) or of the window.
fn grab(hwnd: Option<HWND>, b: Rect) -> Option<Thumbnail> {
    let (w, h) = (b.width as i32, b.height as i32);
    if w <= 0 || h <= 0 {
        return None;
    }
    let tw = w.min(480);
    let th = ((h as f64) * tw as f64 / w as f64).round().max(1.0) as i32;
    unsafe {
        let screen = GetDC(None);
        let full_dc = CreateCompatibleDC(Some(screen));
        let full = CreateCompatibleBitmap(screen, w, h);
        let old_full = SelectObject(full_dc, full.into());
        let ok = match hwnd {
            Some(hwnd) => PrintWindow(hwnd, full_dc, PRINT_WINDOW_FLAGS(PW_RENDERFULLCONTENT)).as_bool(),
            None => BitBlt(full_dc, 0, 0, w, h, Some(screen), b.x as i32, b.y as i32, SRCCOPY).is_ok(),
        };
        let small_dc = CreateCompatibleDC(Some(screen));
        let small: HBITMAP = CreateCompatibleBitmap(screen, tw, th);
        let old_small = SelectObject(small_dc, small.into());
        SetStretchBltMode(small_dc, HALFTONE);
        let _ = StretchBlt(small_dc, 0, 0, tw, th, Some(full_dc), 0, 0, w, h, SRCCOPY);
        let mut bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: tw,
                biHeight: -th, // top-down
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut px = vec![0u8; (tw * th * 4) as usize];
        let lines = GetDIBits(small_dc, small, 0, th as u32, Some(px.as_mut_ptr() as *mut _), &mut bmi, DIB_RGB_COLORS);
        SelectObject(small_dc, old_small);
        SelectObject(full_dc, old_full);
        let _ = DeleteObject(small.into());
        let _ = DeleteObject(full.into());
        let _ = DeleteDC(small_dc);
        let _ = DeleteDC(full_dc);
        ReleaseDC(None, screen);
        if !ok || lines == 0 {
            return None;
        }
        // BGRA -> RGBA, opaque (GDI leaves alpha 0).
        for p in px.chunks_exact_mut(4) {
            p.swap(0, 2);
            p[3] = 255;
        }
        Some(Thumbnail { png: crate::png_rgba(&px, tw as u32, th as u32)?, width: tw as u32, height: th as u32 })
    }
}
