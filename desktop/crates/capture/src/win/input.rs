//! The pointer, clicks and double-tap Shift on Windows. The position is
//! polled with GetCursorPos 120 times a second (as the Mac does); clicks and
//! keys come from low-level hooks, which need no elevation. The hooks only
//! queue what they saw and return: Windows drops hooks that dawdle.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ::windows::Win32::Foundation::{LPARAM, LRESULT, POINT, WPARAM};
use ::windows::Win32::Media::{timeBeginPeriod, timeEndPeriod};
use ::windows::Win32::System::Threading::GetCurrentThreadId;
use ::windows::Win32::UI::HiDpi::{SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use ::windows::Win32::UI::Input::KeyboardAndMouse::{VK_LSHIFT, VK_RSHIFT, VK_SHIFT};
use ::windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetCursorPos, GetMessageW, PostThreadMessageW, SetWindowsHookExW, TranslateMessage,
    UnhookWindowsHookEx, KBDLLHOOKSTRUCT, MSG, MSLLHOOKSTRUCT, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN,
    WM_QUIT, WM_RBUTTONDOWN, WM_SYSKEYDOWN, WM_SYSKEYUP,
};

use super::{sources, Target};
use crate::pointer::Key;
use crate::session::Shared;
use crate::CaptureError;

enum Seen {
    Click { at: Instant, x: i32, y: i32 },
    Key { key: Key, down: bool },
}

/// The hooks' outbox. Hook procedures are plain functions, so it's global;
/// one recording at a time.
static OUTBOX: Mutex<Option<Sender<Seen>>> = Mutex::new(None);

/// Content geometry shared by the poll and the hook worker: the top-left in
/// screen pixels (a window can move) and the file's size, so a point maps
/// onto the video as the encoder pads or crops it.
#[derive(Clone, Copy)]
struct Geometry {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Geometry {
    fn normalise(&self, px: f64, py: f64) -> (f64, f64) {
        ((px - self.x) / self.w.max(1.0), (py - self.y) / self.h.max(1.0))
    }
}

pub(crate) struct Input {
    stop: Arc<AtomicBool>,
    poll: Option<JoinHandle<()>>,
    hooks: Option<(u32, JoinHandle<()>)>,
    worker: Option<JoinHandle<()>>,
}

impl Input {
    pub fn start(shared: Arc<Shared>, target: Target, size: (u32, u32), stop: Arc<AtomicBool>) -> Result<Input, CaptureError> {
        let b = match target {
            Target::Monitor { bounds, .. } | Target::Window { bounds, .. } => bounds,
        };
        let geo = Arc::new(Mutex::new(Geometry { x: b.x, y: b.y, w: size.0 as f64, h: size.1 as f64 }));
        let hwnd = target.hwnd().map(|h| h.0 as isize);

        let (g, sh, st) = (geo.clone(), shared.clone(), stop.clone());
        let poll = std::thread::Builder::new()
            .name("monetshot-pointer".into())
            .spawn(move || poll_pointer(sh, g, hwnd, st))
            .map_err(|e| CaptureError::Other(e.to_string()))?;

        let (tx, rx) = mpsc::channel();
        *OUTBOX.lock().unwrap() = Some(tx);
        let (g, sh) = (geo.clone(), shared.clone());
        let worker = std::thread::Builder::new()
            .name("monetshot-input".into())
            .spawn(move || work(sh, g, rx))
            .map_err(|e| CaptureError::Other(e.to_string()))?;

        let (tid_tx, tid_rx) = mpsc::channel();
        let hooks = std::thread::Builder::new()
            .name("monetshot-hooks".into())
            .spawn(move || run_hooks(tid_tx))
            .map_err(|e| CaptureError::Other(e.to_string()))?;
        let hooks = match tid_rx.recv_timeout(Duration::from_secs(2)) {
            Ok(Ok(tid)) => Some((tid, hooks)),
            Ok(Err(e)) => {
                log::error!("input hooks: {e}");
                shared.emit(crate::Event::Warning("Clicks and double-tap Shift aren't available: Windows refused the input hook.".into()));
                None
            }
            Err(_) => None,
        };
        Ok(Input { stop, poll: Some(poll), hooks, worker: Some(worker) })
    }

    pub fn stop(mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some((tid, h)) = self.hooks.take() {
            unsafe {
                let _ = PostThreadMessageW(tid, WM_QUIT, WPARAM(0), LPARAM(0));
            }
            let _ = h.join();
        }
        // Closing the outbox ends the worker.
        *OUTBOX.lock().unwrap() = None;
        if let Some(w) = self.worker.take() {
            let _ = w.join();
        }
        if let Some(p) = self.poll.take() {
            let _ = p.join();
        }
    }
}

fn poll_pointer(shared: Arc<Shared>, geo: Arc<Mutex<Geometry>>, hwnd: Option<isize>, stop: Arc<AtomicBool>) {
    unsafe {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        // 1 ms timer resolution while recording, so 120 Hz sleeps are honest.
        timeBeginPeriod(1);
    }
    let period = Duration::from_secs_f64(1.0 / 120.0);
    let mut next = Instant::now();
    let mut n: u64 = 0;
    while !stop.load(Ordering::SeqCst) {
        // A window being recorded can move: follow it, 8 times a second.
        if let (Some(h), true) = (hwnd, n.is_multiple_of(15)) {
            if let Some(b) = sources::current_bounds(::windows::Win32::Foundation::HWND(h as *mut _)) {
                let mut g = geo.lock().unwrap();
                g.x = b.x;
                g.y = b.y;
            }
        }
        n += 1;
        let mut p = POINT::default();
        if unsafe { GetCursorPos(&mut p) }.is_ok() {
            let (x, y) = geo.lock().unwrap().normalise(p.x as f64, p.y as f64);
            shared.position(x, y);
        }
        next += period;
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        } else {
            next = now;
        }
    }
    unsafe {
        timeEndPeriod(1);
    }
}

fn work(shared: Arc<Shared>, geo: Arc<Mutex<Geometry>>, rx: Receiver<Seen>) {
    for seen in rx {
        match seen {
            Seen::Click { at, x, y } => {
                let (nx, ny) = geo.lock().unwrap().normalise(x as f64, y as f64);
                shared.click_at(at, nx, ny);
            }
            Seen::Key { key, down } => {
                log::debug!("key {key:?} {}", if down { "down" } else { "up" });
                shared.key(key, down)
            }
        }
    }
}

fn post(s: Seen) {
    if let Some(tx) = OUTBOX.lock().unwrap().as_ref() {
        let _ = tx.send(s);
    }
}

unsafe extern "system" fn mouse_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 && (wparam.0 as u32 == WM_LBUTTONDOWN || wparam.0 as u32 == WM_RBUTTONDOWN) {
        let m = &*(lparam.0 as *const MSLLHOOKSTRUCT);
        post(Seen::Click { at: Instant::now(), x: m.pt.x, y: m.pt.y });
    }
    CallNextHookEx(None, code, wparam, lparam)
}

unsafe extern "system" fn key_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let k = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        let msg = wparam.0 as u32;
        let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
        if down || msg == WM_KEYUP || msg == WM_SYSKEYUP {
            let vk = k.vkCode as u16;
            let key = if vk == VK_SHIFT.0 || vk == VK_LSHIFT.0 || vk == VK_RSHIFT.0 { Key::Shift } else { Key::Other };
            post(Seen::Key { key, down });
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

/// Installs both hooks and pumps messages (LL hooks are called on the
/// installing thread's message loop) until WM_QUIT.
fn run_hooks(ready: Sender<Result<u32, String>>) {
    unsafe {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let mouse = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook), None, 0);
        let keys = SetWindowsHookExW(WH_KEYBOARD_LL, Some(key_hook), None, 0);
        let (mouse, keys) = match (mouse, keys) {
            (Ok(m), Ok(k)) => (m, k),
            (m, k) => {
                let e = m.as_ref().err().or(k.as_ref().err()).map(|e| e.to_string()).unwrap_or_default();
                if let Ok(m) = m {
                    let _ = UnhookWindowsHookEx(m);
                }
                if let Ok(k) = k {
                    let _ = UnhookWindowsHookEx(k);
                }
                let _ = ready.send(Err(e));
                return;
            }
        };
        let _ = ready.send(Ok(GetCurrentThreadId()));
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        let _ = UnhookWindowsHookEx(mouse);
        let _ = UnhookWindowsHookEx(keys);
    }
}
