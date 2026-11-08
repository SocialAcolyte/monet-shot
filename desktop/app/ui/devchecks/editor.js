// Drives the editor like a person would (keys, drags, clicks) and logs what
// happened, for checking a dev build where nobody can click: this Mac from a
// terminal, or Linux under Xvfb.
//
//   MONETSHOT_DEV_SCRIPT=$PWD/desktop/app/ui/devchecks/editor.js \
//     ./target/debug/monet-shot <copy of a recording>.reel
//
// Lines go to the app log as "check: ok …" / "check: FAIL …", then
// "check: done N ok, M failed". It edits the recording: use a copy.

export default async function ({ view, call }) {
  if (view !== "editor") return;
  const log = (m) => call("ui_log", { level: m.startsWith("FAIL") ? "error" : "info", message: `check: ${m}` });
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
  // A new edit is its own undo step only 0.6 s after the last.
  const settle = () => wait(700);
  const key = (k, o = {}) => dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, ...o }));
  const centre = (el) => {
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };
  /** A pointer drag on `el` from (x, y) by (dx, dy), in steps. */
  const drag = async (el, x, y, dx, dy = 0) => {
    const ev = (type, px, py) =>
      new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 7, button: 0, buttons: type === "pointerup" ? 0 : 1, clientX: px, clientY: py, isPrimary: true });
    el.dispatchEvent(ev("pointerdown", x, y));
    for (let i = 1; i <= 8; i++) {
      el.dispatchEvent(ev("pointermove", x + (dx * i) / 8, y + (dy * i) / 8));
      await wait(16);
    }
    el.dispatchEvent(ev("pointerup", x + dx, y + dy));
    await wait(50);
  };
  const click = async (el) => {
    el.click();
    await wait(60);
  };

  if (!(await until(() => window.monetshot, 15000))) return log("FAIL the editor never opened");
  const s = window.monetshot;
  await wait(1500);
  await log(`opened ${s.name}: ${s.takes.length} take(s), ${s.clips.length} clip(s), ${s.duration.toFixed(2)} s`);

  // Keys: zoom, delete, undo, redo, split.
  s.seek(1.0);
  const zooms = s.edit.segments.length;
  await settle();
  key("z");
  await ok(s.edit.segments.length === zooms + 1 && s.selectedID, "Z adds a selected zoom");
  await settle();
  key("Delete");
  await ok(s.edit.segments.length === zooms, "Delete removes the selected zoom");
  key("z", { ctrlKey: true });
  await ok(s.edit.segments.length === zooms + 1, "Ctrl+Z brings it back");
  key("z", { ctrlKey: true, shiftKey: true });
  await ok(s.edit.segments.length === zooms, "Ctrl+Shift+Z removes it again");
  await settle();
  const clips = s.clips.length;
  key("s");
  await ok(s.clips.length === clips + 1 && s.selectedClip != null, "S splits the clip at the playhead");
  key("z", { ctrlKey: true });
  await ok(s.clips.length === clips, "undo the split");
  const t0 = s.time;
  key("ArrowRight", { shiftKey: true });
  await ok(Math.abs(s.time - (t0 + 1)) < 0.02, "Shift+→ steps a second", `${t0.toFixed(2)} → ${s.time.toFixed(2)}`);
  key("ArrowLeft");
  await ok(Math.abs(s.time - (t0 + 1 - 1 / 60)) < 0.02, "← steps a frame");

  // Timeline: scrub, trim a clip's end, move a zoom.
  await settle();
  const ruler = document.querySelector(".ruler");
  const rr = ruler.getBoundingClientRect();
  await drag(ruler, rr.left + rr.width * 0.5, rr.top + 10, 0);
  await ok(Math.abs(s.time - s.duration / 2) < s.duration * 0.06, "the ruler scrubs", `t = ${s.time.toFixed(2)} of ${s.duration.toFixed(2)}`);

  const d0 = s.duration;
  const lastClip = [...document.querySelectorAll(".timeline .clip")].at(-1);
  const trailing = lastClip.querySelectorAll(".handle")[1];
  const hc = centre(trailing);
  await drag(trailing, hc.x, hc.y, -60);
  await ok(s.duration < d0 - 0.2, "dragging a clip's end shortens it", `${d0.toFixed(2)} → ${s.duration.toFixed(2)} s`);
  await settle();
  key("z", { ctrlKey: true });
  await ok(Math.abs(s.duration - d0) < 0.01, "undo the trim");

  await settle();
  const pill = document.querySelector(".timeline .zoom");
  if (pill) {
    const before = s.edit.segments.map((x) => x.start).join();
    const pc = centre(pill);
    await drag(pill, pc.x, pc.y, 40);
    await ok(s.edit.segments.map((x) => x.start).join() !== before, "a zoom moves when dragged");
    await settle();
    key("z", { ctrlKey: true });
  } else await log("skip zoom drag (no zoom)");

  // Clip reorder (needs two clips).
  if (s.clips.length > 1) {
    await settle();
    const first = document.querySelector(".timeline .clip");
    const order = JSON.stringify(s.clips);
    const fc = centre(first);
    const w = document.querySelector(".timeline").getBoundingClientRect().width;
    await drag(first, fc.x, fc.y, w * 0.8);
    await ok(JSON.stringify(s.clips) !== order, "dragging a clip's middle reorders it");
    await settle();
    key("z", { ctrlKey: true });
    await ok(JSON.stringify(s.clips) === order, "undo the move");
  }

  // Framing: draw a box, switch to crop, drag an edge, leave.
  await settle();
  key("b");
  await until(() => document.querySelector(".frame-overlay"));
  await ok(s.framing, "B opens framing");
  const ov = document.querySelector(".frame-overlay");
  const orr = ov.getBoundingClientRect();
  const blurs = s.edit.blurs.length;
  await drag(ov, orr.left + orr.width * 0.4, orr.top + orr.height * 0.4, 80, 50);
  await ok(s.edit.blurs.length === blurs + 1 && s.selectedBlurID, "dragging on the preview draws a hide box");
  await settle();
  key("r");
  await ok(s.frameTool === "crop", "R switches to crop");
  await wait(100);
  const handles = document.querySelectorAll(".frame-overlay .handle");
  if (handles.length) {
    const h = handles[handles.length - 1];
    const c = centre(h);
    await drag(h, c.x, c.y, -60, -40);
    await ok(s.edit.crops.length === 1 && s.edit.crops[0].rect.w < 1, "dragging the crop's corner crops", JSON.stringify(s.edit.crops[0]?.rect));
  } else await ok(false, "crop handles are shown");
  key("Escape");
  key("Escape");
  await ok(!s.framing, "Esc leaves framing");

  // Inspector: swatches, painting, slider, cursor look, output.
  await settle();
  const paper = document.querySelector('.swatch[aria-label="Paper"]');
  await click(paper);
  await ok(s.edit.backdrop === "paper", "the Paper swatch sets the backdrop");
  await settle();
  await click(document.querySelector('.swatch[aria-label="Picture"]'));
  await until(() => s.edit.backdrop === "image" && s.edit.backdropImage);
  await ok(s.edit.backdrop === "image" && !!s.edit.backdropImage, "the picture swatch picks a painting", s.edit.backdropImage ?? "");
  await until(() => document.querySelectorAll(".painting").length > 3);
  const paintings = document.querySelectorAll(".painting");
  if (paintings.length > 3) {
    await settle();
    await click(paintings[3]);
    await until(() => s.edit.backdropImage && paintings[3].classList.contains("sel"), 5000);
    await ok(paintings[3].classList.contains("sel"), "a painting tile becomes the backdrop", s.edit.backdropImage ?? "");
  } else await ok(false, "the gallery lists the paintings", `${paintings.length}`);
  await settle();
  const padding = [...document.querySelectorAll(".inspector input[type=range]")].find((i) => i.closest(".row")?.textContent?.includes("Padding"));
  if (padding) {
    padding.value = "0.03";
    padding.dispatchEvent(new Event("input", { bubbles: true }));
    await ok(Math.abs(s.edit.padding - 0.03) < 0.001, "the Padding slider sets the padding");
  } else await ok(false, "there is a Padding slider");
  await settle();
  const dot = document.querySelector('.cursors button[aria-label="Dot"]');
  if (dot) {
    await click(dot);
    await ok(s.edit.cursorStyle === "dot", "the Dot tile sets the cursor look");
  } else await log("skip cursor tiles (cursor hidden)");
  await settle();
  const p1080 = [...document.querySelectorAll(".seg button")].find((b) => b.textContent.trim() === "1080p");
  await click(p1080);
  await ok(s.edit.outputWidth === 1920, "Output 1080p");

  // Playback: the clock runs and the picture keeps up.
  s.seek(0);
  key(" ");
  await wait(2000);
  const played = s.time;
  key(" ");
  await ok(!s.playing && played > 1.2 && played < 2.8, "Space plays and pauses", `${played.toFixed(2)} s after 2 s`);

  // Saved edit.json says the same as the page.
  await s.save();
  const back = await call("editor_load", { path: s.folder });
  await ok(back.edit.backdropImage === s.edit.backdropImage && back.edit.outputWidth === s.edit.outputWidth, "edit.json is saved");

  // Music: the browser beside the video, a track heard under it, then used.
  await settle();
  s.openMusic();
  await until(() => document.querySelectorAll('.panel[aria-label="Music"] li').length > 0, 10000);
  const rows = () => [...document.querySelectorAll('.panel[aria-label="Music"] li')];
  await ok(rows().length >= 4, "the music browser suggests tracks for this video", `${rows().length}`);
  await ok(rows().every((li) => li.querySelectorAll("svg.wave rect").length >= 32), "every track shows its waveform");
  const chip = (t) => [...document.querySelectorAll('.panel[aria-label="Music"] .chip')].find((b) => b.textContent.trim() === t);
  await click(chip("Punchy"));
  await until(() => rows().length > 0);
  const punchy = rows().length;
  await click(chip("Upbeat"));
  await wait(300);
  await ok(punchy >= 5 && rows().length > 0 && rows().length <= punchy, "moods and tempo filter the list", `${punchy} punchy, ${rows().length} upbeat`);
  await click(chip("Upbeat"));
  await click(chip("For this video"));
  await until(() => rows().length > 0);
  const favs = () => JSON.parse(localStorage.getItem("monetshot.musicFavourites") ?? "[]");
  const before = favs().length;
  const heart = rows()[0].querySelector(".heart");
  await click(heart);
  await ok(favs().length === before + 1, "the heart keeps a favourite (remembered)", favs().join(","));
  await click(heart);
  // Hear one under the video.
  await click(rows()[1].querySelector(".row"));
  await until(() => s.audition && s.playing, 3000);
  await wait(2500);
  const audio = document.querySelector("audio");
  await ok(!!s.audition && !!audio && !audio.paused && audio.currentTime > (s.audition?.offset ?? 0) + 0.5,
    "a track plays under the video", `${s.audition?.track.title} from ${(s.audition?.offset ?? 0).toFixed(2)} s, at ${audio?.currentTime.toFixed(2)} s`);
  await log("music browser open");
  await wait(6000); // the run takes its screenshot now
  const heard = s.audition;
  await click(document.querySelector('.panel[aria-label="Music"] footer .pill-button'));
  await until(() => s.edit.music && !s.showingMusic, 20000);
  const m = s.edit.music;
  const g = m?.track.grid;
  const onBeat = g ? Math.abs(((m.offset - g.firstDownbeat) / g.bar) - Math.round((m.offset - g.firstDownbeat) / g.bar)) < 1e-6 : true;
  await ok(!!m && m.track.id === heard?.track.id && Math.abs(m.offset - heard.offset) < 1e-9 && onBeat,
    "Use puts it in the edit, from a downbeat", `${m?.track.title} from ${m?.offset.toFixed(3)} s`);
  if (s.playing) key(" ");
  await s.save();

  // Export (Ctrl/⌘+E) to the end.
  if (new URLSearchParams(location.search).has("t") === false) {
    key("e", { ctrlKey: true });
    const started = await until(() => s.exportProgress != null, 5000);
    await ok(started, "Ctrl+E starts the export");
    const t1 = performance.now();
    const done = await until(() => s.exportProgress == null && (s.exportedPath || s.exportError), 600000);
    await ok(done && !!s.exportedPath, "the export finishes", `${s.exportedPath ?? s.exportError} in ${((performance.now() - t1) / 1000).toFixed(0)} s`);
  }

  await log(`done ${good} ok, ${bad} failed`);
}
