// Drives Home and the editor's clip tools in a dev build, for the CI runs
// (Windows: desktop/tools/windows-run.ps1, stage "home"; Linux/Omarchy can
// run it the same way). It needs MONETSHOT_HOME=<home> with two recordings
// in <home>/recordings named "Open me.reel" and "Trash me.reel", and a
// video at <home>/footage.mp4. It edits and trashes them: use copies.
//
//   MONETSHOT_DEV_SCRIPT=$PWD/desktop/app/ui/devchecks/home.js ./target/debug/monet-shot
//
//   home:   two cards with thumbnails; Move to Trash (the context menu's
//           command: the menu itself is native) drops the card; Show in
//           folder (its command) opens the file manager; clicking the
//           "Open me" card opens it in the editor.
//   editor: Add a video (the same add_footage + footageAdded as the Add
//           clip handler) adds a take and a clip; Record a new take (the
//           menu's store.recordTake) goes through the picker, 3-2-1 and a
//           recording, which the CI script stops; its clips arrive; dragging
//           a clip reorders it, undo puts it back; the takes are saved.
//   picker: picks the first display (our picker: Windows, macos-dev).
//
// Lines go to the app log as "home: ok …" / "home: FAIL …"; the editor ends
// with "home: done N ok, M failed" (its own checks; the CI script also
// counts the home view's FAIL lines).

export default async function ({ view, call }) {
  const log = (m) => call("ui_log", { level: m.startsWith("FAIL") ? "error" : "info", message: `home: ${m}` });
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const until = async (f, ms = 8000) => {
    const t0 = performance.now();
    while (performance.now() - t0 < ms) {
      const v = f();
      if (v) return v;
      await wait(100);
    }
    return null;
  };
  let good = 0, bad = 0;
  const ok = async (cond, name, detail = "") => {
    if (cond) good++;
    else bad++;
    await log(`${cond ? "ok" : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`);
  };
  const cards = () => [...document.querySelectorAll(".card")];
  const titled = (t) => cards().find((c) => c.querySelector(".title")?.textContent?.includes(t));

  if (view === "home") {
    await until(() => cards().length >= 2, 20000);
    await ok(cards().length === 2, "Home shows both recordings", `${cards().length} cards`);
    const thumbs = await until(() => {
      const imgs = [...document.querySelectorAll(".card .thumb img")];
      return imgs.length === cards().length && imgs.every((i) => i.complete && i.naturalWidth > 0) && imgs;
    }, 60000);
    await ok(!!thumbs, "every card shows its thumbnail");

    const items = await call("home_items");
    const trash = items.find((i) => i.title.includes("Trash me"));
    const keep = items.find((i) => i.title.includes("Open me"));
    if (!trash || !keep) return log(`FAIL the library isn't set up (${items.map((i) => i.title).join(", ")})`);
    try {
      await call("trash", { path: trash.path });
      await until(() => cards().length === 1 && !titled("Trash me"), 10000);
      await ok(cards().length === 1 && !titled("Trash me"), "Move to Trash removes the card", trash.path);
    } catch (e) {
      await ok(false, "Move to Trash", String(e));
    }
    try {
      await call("reveal", { path: keep.path });
      await ok(true, "Show in folder opens the file manager", keep.path);
    } catch (e) {
      await ok(false, "Show in folder", String(e));
    }
    await wait(1000);
    const card = titled("Open me");
    if (!card) return log("FAIL no Open me card to click");
    await log("clicking the Open me card");
    card.click();
    return;
  }

  if (view === "picker") {
    const card = await until(() => document.querySelector(".card"), 20000);
    if (!card) return log("FAIL the picker shows nothing to record");
    await log(`picking "${card.querySelector(".title")?.textContent}"`);
    card.click();
    return;
  }

  if (view !== "editor") return;
  if (!(await until(() => window.monetshot, 30000))) return log("FAIL the editor never opened");
  const s = window.monetshot;
  await wait(1500);
  await ok(s.name.includes("Open me"), "clicking a card opens it in the editor", s.name);
  const settle = () => wait(700);
  const key = (k, o = {}) => dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, ...o }));
  const drag = async (el, x, y, dx) => {
    const ev = (type, px) =>
      new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 7, button: 0, buttons: type === "pointerup" ? 0 : 1, clientX: px, clientY: y, isPrimary: true });
    el.dispatchEvent(ev("pointerdown", x));
    for (let i = 1; i <= 8; i++) {
      el.dispatchEvent(ev("pointermove", x + (dx * i) / 8));
      await wait(16);
    }
    el.dispatchEvent(ev("pointerup", x + dx));
    await wait(50);
  };

  // Add a video: <home>/footage.mp4.
  const sep = s.folder.includes("\\") ? "\\" : "/";
  const home = s.folder.split(/[\\/]/).slice(0, -2).join(sep);
  const footage = `${home}${sep}footage.mp4`;
  const t0 = s.takes.length, c0 = s.clips.length;
  try {
    const r = await call("add_footage", { folder: s.folder, paths: [footage], edit: s.edit });
    await s.footageAdded(r.edit, r.videoTakes);
    await ok(s.takes.length === t0 + 1 && s.clips.length === c0 + 1, "Add a video adds a take and a clip", `${t0}→${s.takes.length} takes, ${c0}→${s.clips.length} clips`);
  } catch (e) {
    await ok(false, "Add a video", String(e));
  }

  // Record a new take: the picker, 3-2-1, recording (stopped by the CI script).
  await settle();
  const t1 = s.takes.length, c1 = s.clips.length;
  await log("recording a new take");
  s.recordTake();
  const took = await until(() => s.takes.length > t1, 120000);
  await wait(500);
  await ok(!!took && s.clips.length > c1, "Record a new take adds its clips", `${t1}→${s.takes.length} takes, ${c1}→${s.clips.length} clips`);

  // Reorder: drag the first clip towards the end, then undo.
  if (s.clips.length > 1) {
    await settle();
    const first = document.querySelector(".timeline .clip");
    const order = JSON.stringify(s.clips);
    const r = first.getBoundingClientRect();
    const w = document.querySelector(".timeline").getBoundingClientRect().width;
    await drag(first, r.left + r.width / 2, r.top + r.height / 2, w * 0.8);
    await ok(JSON.stringify(s.clips) !== order, "dragging a clip's middle reorders it", s.clips.map((c) => c.take).join(","));
    await settle();
    key("z", { ctrlKey: true });
    await ok(JSON.stringify(s.clips) === order, "undo the move");
  } else await ok(false, "two clips to reorder", `${s.clips.length}`);

  await s.save();
  const back = await call("editor_load", { path: s.folder });
  await ok(back.takes.length === s.takes.length, "the takes are saved", `${back.takes.length} takes`);
  await log(`done ${good} ok, ${bad} failed`);
}
