// Checks the vertical layout in a running editor (windows-run's stage 9):
// open a recording already made vertical (`monet-shot --vertical`), then
// look at the canvas, the follow window, the safe-area guides and the
// Shape control, switch to Landscape and back, and flip Record Vertical.
//
//   MONETSHOT_DEV_SCRIPT=$PWD/desktop/app/ui/devchecks/vertical.js \
//     ./target/debug/monet-shot <vertical copy of a recording>.reel
//
// Lines go to the app log as "vertical: ok …" / "vertical: FAIL …", then
// "vertical: done N ok, M failed". "vertical: shown" marks the moment for
// a screenshot of the tall preview.

export default async function ({ view, call }) {
  if (view !== "editor") return;
  const log = (m) => call("ui_log", { level: m.startsWith("FAIL") ? "error" : "info", message: `vertical: ${m}` });
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const until = async (f, ms = 8000) => {
    const t0 = performance.now();
    while (performance.now() - t0 < ms) {
      if (f()) return true;
      await wait(50);
    }
    return false;
  };
  let good = 0, bad = 0;
  const ok = async (cond, name, detail = "") => {
    if (cond) good++;
    else bad++;
    await log(`${cond ? "ok" : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`);
  };
  const radio = (label) => [...document.querySelectorAll('[role="radio"]')].find((b) => b.textContent.trim() === label);

  if (!(await until(() => window.monetshot, 15000))) return log("FAIL the editor never opened");
  const s = window.monetshot;
  await wait(1500);
  await log(`opened ${s.name}: ${s.duration.toFixed(2)} s, layout ${s.edit.layout ?? "landscape"}`);

  const c = s.canvas;
  await ok(c.width === 1080 && c.height === 1920, "the canvas is 1080x1920", `${c.width}x${c.height}`);
  const t = Math.min(2, s.duration / 2);
  s.seek(t);
  const plan = s.editor.plan(t);
  await ok(plan.camera.window > 0.2 && plan.camera.window < 0.9, "a wide take is seen through a tall window", `window ${plan.camera.window.toFixed(3)}`);
  const f = plan.frame;
  await ok(f.h > 1920 * 0.8 && f.w > 1080 * 0.8, "the recording fills the phone frame", `${f.w}x${f.h}`);
  await ok(Math.abs(f.w / plan.source.rect.w - f.h / plan.source.rect.h) < 1e-6, "one scale on both axes");
  const safe = s.c.safeArea(1080, 1920);
  await ok(safe.y === 230 && safe.h === 1306, "the safe area keeps clear of the phone apps' bands", JSON.stringify(safe));
  await ok(await until(() => document.querySelector("[data-safe-guides]")), "the preview shows the safe-area guides");
  await ok(radio("Vertical")?.getAttribute("aria-checked") === "true", "Shape shows Vertical");
  // The preview is drawn: time for a screenshot.
  await wait(1500);
  await log("shown");
  await wait(5000);

  const before = JSON.stringify({ w: s.edit.outputWidth, a: s.edit.canvasAspect });
  radio("Landscape")?.click();
  await wait(400);
  const l = s.canvas;
  await ok(!("layout" in s.edit) && l.width === s.edit.outputWidth, "Landscape restores the landscape canvas", `${l.width}x${l.height}`);
  await ok(JSON.stringify({ w: s.edit.outputWidth, a: s.edit.canvasAspect }) === before, "the landscape choices are untouched");
  await ok(await until(() => !document.querySelector("[data-safe-guides]"), 2000), "no guides in landscape");
  await ok(s.editor.plan(t).camera.window === 1, "landscape shows the take whole");
  radio("Vertical")?.click();
  await wait(400);
  await ok(s.edit.layout === "vertical" && s.canvas.height === 1920, "Vertical again");

  const b0 = await call("bar_state");
  await call("bar_toggle_vertical");
  const b1 = await call("bar_state");
  await call("bar_toggle_vertical");
  const b2 = await call("bar_state");
  await ok(b1.vertical === !b0.vertical && b2.vertical === b0.vertical, "Record Vertical flips and flips back", `${b0.vertical} → ${b1.vertical} → ${b2.vertical}`);

  await log(`done ${good} ok, ${bad} failed`);
}
