//! The record state machine, after the Mac's `MenuBarModel`. The tray and the
//! pill read it; only its methods change it.
//!
//!   idle --tap--> picking --picked--> countdown(3,2,1) --> starting --> recording
//!   recording --hold the ring--> saving --> idle (editor opens)
//!   picking/countdown --tap--> idle

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use crate::recorder::{self, Event};
use crate::{camera, log, tray, windows};

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Phase {
    Idle,
    Picking,
    Countdown { n: u8 },
    Starting,
    /// `since` in ms since the Unix epoch.
    Recording { since: u64 },
    Saving,
}

/// `take-finished`: a take recorded into an open project.
#[derive(Clone, Debug, Serialize)]
pub struct TakeFinished {
    pub project: PathBuf,
    pub clips: Vec<monetshot_core::Clip>,
}

/// What the UI sees: emitted as `bar` on every change.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BarState {
    pub phase: Phase,
    /// Paused mid-recording (the paused stretch will be cut).
    pub paused: bool,
    /// Paused time so far (ms), so the clock shows recorded time only.
    pub paused_total: u64,
    /// When the current pause began (ms since epoch).
    pub paused_since: Option<u64>,
    /// A short message shown for a few seconds after a failure.
    pub problem: Option<String>,
    /// "Record My Camera Too".
    pub camera_too: bool,
}

pub struct Bar {
    state: Mutex<BarState>,
    /// Bumped by every countdown/problem timer start, so a stale timer stops.
    countdown_gen: Mutex<u64>,
    problem_gen: Mutex<u64>,
    /// A take is being recorded into this existing recording.
    take_target: Mutex<Option<PathBuf>>,
}

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl Bar {
    pub fn new(camera_too: bool) -> Self {
        Bar {
            state: Mutex::new(BarState {
                phase: Phase::Idle,
                paused: false,
                paused_total: 0,
                paused_since: None,
                problem: None,
                camera_too,
            }),
            countdown_gen: Mutex::new(0),
            problem_gen: Mutex::new(0),
            take_target: Mutex::new(None),
        }
    }

    pub fn snapshot(&self) -> BarState {
        self.state.lock().unwrap().clone()
    }

    pub fn is_recording(&self) -> bool {
        matches!(self.state.lock().unwrap().phase, Phase::Recording { .. })
    }

    /// Recorded seconds now, not counting pauses.
    pub fn elapsed(&self) -> f64 {
        let s = self.state.lock().unwrap();
        let Phase::Recording { since } = s.phase else { return 0.0 };
        let now = now_ms();
        let paused_now = s.paused_since.map(|p| now.saturating_sub(p)).unwrap_or(0);
        now.saturating_sub(since).saturating_sub(s.paused_total).saturating_sub(paused_now) as f64 / 1000.0
    }

    fn set(&self, app: &AppHandle, change: impl FnOnce(&mut BarState)) {
        let snap = {
            let mut s = self.state.lock().unwrap();
            change(&mut s);
            s.clone()
        };
        tray::update(app, &snap);
        windows::pill_follow(app, &snap);
        let _ = app.emit("bar", &snap);
        self.publish();
    }

    /// For Waybar and other processes (`monet-shot status`).
    pub fn publish(&self) {
        use monetshot_capture::status::{self, Phase as P, Status};
        let s = self.snapshot();
        let (phase, countdown) = match s.phase {
            Phase::Idle => (P::Idle, None),
            Phase::Picking => (P::Picking, None),
            Phase::Countdown { n } => (P::Countdown, Some(n)),
            Phase::Starting => (P::Starting, None),
            Phase::Recording { .. } => (P::Recording, None),
            Phase::Saving => (P::Saving, None),
        };
        status::publish(&Status {
            phase,
            countdown,
            elapsed: self.elapsed(),
            paused: s.paused,
            problem: s.problem,
            pid: 0,
        });
    }

    fn phase(&self) -> Phase {
        self.state.lock().unwrap().phase
    }

    /// A left click on the ring (or "Record…").
    pub fn tap(&self, app: &AppHandle) {
        match self.phase() {
            Phase::Idle => {
                self.set(app, |s| {
                    s.problem = None;
                    s.phase = Phase::Picking;
                });
                recorder::pick(app);
            }
            Phase::Countdown { .. } => self.cancel(app),
            // A recording only stops through the hold ring.
            Phase::Picking | Phase::Starting | Phase::Recording { .. } | Phase::Saving => {}
        }
    }

    pub fn cancel(&self, app: &AppHandle) {
        *self.countdown_gen.lock().unwrap() += 1;
        if matches!(self.phase(), Phase::Countdown { .. } | Phase::Starting) {
            self.put_camera_away(app);
        }
        recorder::cancel_pending(app);
        *self.take_target.lock().unwrap() = None;
        if matches!(self.phase(), Phase::Picking | Phase::Countdown { .. }) {
            self.set(app, |s| s.phase = Phase::Idle);
            windows::hide_for_recording(app, false);
        }
    }

    /// Records a new take for the recording in `folder` (from its editor).
    pub fn record_take(&self, app: &AppHandle, folder: PathBuf) {
        if self.phase() != Phase::Idle {
            return;
        }
        *self.take_target.lock().unwrap() = Some(folder);
        self.tap(app);
    }

    pub fn take_target(&self) -> Option<PathBuf> {
        self.take_target.lock().unwrap().clone()
    }

    /// Pause or resume (also double-tap Shift while recording).
    pub fn toggle_pause(&self, app: &AppHandle) {
        if self.is_recording() {
            recorder::toggle_pause(app);
        }
    }

    pub fn stop(&self, app: &AppHandle) {
        if !self.is_recording() {
            return;
        }
        self.set(app, |s| s.phase = Phase::Saving);
        recorder::stop(app);
        log::info("stop requested");
    }

    /// `monet-shot toggle` (Waybar click): a deliberate act, so a recording
    /// stops without the hold.
    pub fn toggle_from_cli(&self, app: &AppHandle) {
        match self.phase() {
            Phase::Idle => self.tap(app),
            Phase::Picking | Phase::Countdown { .. } => self.cancel(app),
            Phase::Recording { .. } => self.stop(app),
            Phase::Starting | Phase::Saving => {}
        }
    }

    pub fn toggle_camera_too(&self, app: &AppHandle) {
        self.set(app, |s| s.camera_too = !s.camera_too);
        crate::settings::save_camera_too(self.snapshot().camera_too);
    }

    /// The recorder reports.
    pub fn handle(&self, app: &AppHandle, e: Event) {
        match e {
            Event::PickerClosed => {
                if self.phase() == Phase::Picking {
                    self.set(app, |s| s.phase = Phase::Idle);
                }
                *self.take_target.lock().unwrap() = None;
            }
            Event::Picked => {
                windows::hide_for_recording(app, true);
                self.start_countdown(app);
                // Recording yourself too: see yourself while it counts in.
                if self.snapshot().camera_too {
                    let app = app.clone();
                    std::thread::spawn(move || {
                        if !camera::acquire("bar") {
                            return;
                        }
                        let bar = app.state::<Bar>();
                        match bar.phase() {
                            Phase::Countdown { .. } => windows::show_bubble(&app),
                            Phase::Idle => camera::release("bar"),
                            _ => {}
                        }
                    });
                }
            }
            Event::Started => {
                windows::hide_bubble(app); // it would be in the recording
                self.set(app, |s| {
                    s.phase = Phase::Recording { since: now_ms() };
                    s.paused = false;
                    s.paused_total = 0;
                    s.paused_since = None;
                });
                // Developer aid: MONETSHOT_DEMO_STOP=<s> stops the demo take.
                if let Some(secs) = std::env::var("MONETSHOT_DEMO_STOP").ok().and_then(|v| v.parse::<f64>().ok()) {
                    let app = app.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_secs_f64(secs));
                        let a = app.clone();
                        let _ = app.run_on_main_thread(move || a.state::<Bar>().stop(&a));
                    });
                }
            }
            Event::Paused(on) => self.set(app, |s| {
                let now = now_ms();
                if on {
                    s.paused_since = Some(now);
                } else if let Some(p) = s.paused_since.take() {
                    s.paused_total += now.saturating_sub(p);
                }
                s.paused = on;
            }),
            Event::Finished { folder } => {
                self.finished(app);
                windows::open_editor(app, &folder);
            }
            Event::FinishedTake { project, clips } => {
                self.finished(app);
                // The open editor adds the take's clips at the end.
                let _ = app.emit("take-finished", TakeFinished { project: project.clone(), clips });
                windows::open_editor(app, &project);
            }
            Event::Failed(message) => {
                log::error(&message);
                self.put_camera_away(app);
                *self.take_target.lock().unwrap() = None;
                windows::hide_for_recording(app, false);
                self.set(app, |s| {
                    s.phase = Phase::Idle;
                    s.paused = false;
                });
                self.show_problem(app, "Couldn't record");
            }
        }
    }

    /// The bubble goes and the camera is let go.
    fn put_camera_away(&self, app: &AppHandle) {
        windows::hide_bubble(app);
        camera::release("bar");
    }

    fn finished(&self, app: &AppHandle) {
        self.put_camera_away(app);
        crate::commands::library_changed(app);
        *self.take_target.lock().unwrap() = None;
        self.set(app, |s| {
            s.phase = Phase::Idle;
            s.paused = false;
        });
        windows::hide_for_recording(app, false);
    }

    fn start_countdown(&self, app: &AppHandle) {
        let gen = {
            let mut g = self.countdown_gen.lock().unwrap();
            *g += 1;
            *g
        };
        let app = app.clone();
        std::thread::spawn(move || {
            let bar = app.state::<Bar>();
            for n in [3u8, 2, 1] {
                if *bar.countdown_gen.lock().unwrap() != gen {
                    return;
                }
                bar.set(&app, |s| s.phase = Phase::Countdown { n });
                std::thread::sleep(Duration::from_secs(1));
            }
            if *bar.countdown_gen.lock().unwrap() != gen {
                return;
            }
            bar.set(&app, |s| s.phase = Phase::Starting);
            recorder::begin_recording(&app, bar.take_target(), bar.snapshot().camera_too);
        });
    }

    fn show_problem(&self, app: &AppHandle, text: &str) {
        let gen = {
            let mut g = self.problem_gen.lock().unwrap();
            *g += 1;
            *g
        };
        self.set(app, |s| s.problem = Some(text.to_string()));
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(4));
            let bar = app.state::<Bar>();
            if *bar.problem_gen.lock().unwrap() == gen {
                bar.set(&app, |s| s.problem = None);
            }
        });
    }
}

/// The bar's elapsed-time text, "0:07" or "12:41".
pub fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

#[cfg(test)]
mod tests {
    use super::clock;

    #[test]
    fn clock_matches_the_mac() {
        assert_eq!(clock(7.9), "0:07");
        assert_eq!(clock(761.0), "12:41");
        assert_eq!(clock(3725.0), "1:02:05");
        assert_eq!(clock(-3.0), "0:00");
    }
}
