// Dev script for the Windows CI run (windows-run.ps1, stage "hevc"): opened
// on a take whose screen.mp4 is HEVC, checks that the editor's preview gets a
// picture (through ms-capture's H.264 video_proxy when the engine can't play
// HEVC) and that playback runs. Logs "hevc: …" lines, then
// "hevc: done plays|FAIL …".
//
//   MONETSHOT_DEV_SCRIPT=<abs>/desktop/tools/windows-hevc-check.js monet-shot <copy>.reel

export default async function ({ view, call }) {
  if (view !== "editor") return;
  const log = (m) => call("ui_log", { level: m.includes("FAIL") ? "error" : "info", message: `hevc: ${m}` });
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const until = async (f, ms) => {
    const t0 = performance.now();
    while (performance.now() - t0 < ms) {
      if (f()) return true;
      await wait(100);
    }
    return false;
  };
  if (!(await until(() => window.monetshot, 30000))) return log("done FAIL the editor never opened");
  const s = window.monetshot;
  const videos = () => [...document.querySelectorAll("video")];
  const t0 = performance.now();
  // The proxy is made on first open: give ffmpeg time.
  const shown = await until(() => videos().some((v) => v.videoWidth > 0 && v.readyState >= 2), 240000);
  const v = videos().find((v) => v.videoWidth > 0) ?? videos()[0];
  const src = v?.currentSrc ?? "";
  await log(`picture ${shown ? "yes" : "no"} after ${((performance.now() - t0) / 1000).toFixed(1)} s: ${v?.videoWidth}x${v?.videoHeight} from ${src}`);
  await log(`proxy ${/proxies/.test(decodeURIComponent(src)) ? "yes" : "no"}`);
  if (!shown) return log("done FAIL no picture");
  s.seek(0);
  await wait(500);
  dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true }));
  await wait(2000);
  const played = s.time;
  const vt = v.currentTime;
  dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true }));
  const plays = played > 1.2 && played < 2.8 && vt > 0.5;
  await log(`done ${plays ? "plays" : "FAIL doesn't play"} (clock ${played.toFixed(2)} s, video ${vt.toFixed(2)} s after 2 s)`);
}
