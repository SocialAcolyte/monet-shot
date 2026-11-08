// Captions, end to end in a dev build: open a take whose voice is the test
// sentence (shared/fixtures/voice), let it transcribe itself on open
// (whisper, the model downloaded on first use), check what it heard, fix a
// word in the transcript panel, see the captions in the plan, and export
// (the .srt lands beside the video).
//
//   MONETSHOT_DEV_SCRIPT=$PWD/desktop/app/ui/devchecks/captions.js \
//     ./target/debug/monet-shot <a .reel whose meta.voice is the sentence>
//
// Lines go to the app log as "check: ok …" / "check: FAIL …", then
// "check: done N ok, M failed". "check: shot <name>" asks the runner for a
// screenshot now (it waits 4 s before going on).

const SENTENCE = "Monet Shot turns a screen recording into a polished demo video, with zooms decided after recording.";

function wer(expected, heard) {
  const norm = (s) => s.split(/\s+/).map((w) => w.replace(/[^\p{L}\p{N}']/gu, "").toLowerCase()).filter(Boolean);
  const a = norm(expected), b = norm(heard);
  let d = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const n = [i];
    for (let j = 1; j <= b.length; j++) n[j] = a[i - 1] === b[j - 1] ? d[j - 1] : 1 + Math.min(d[j - 1], d[j], n[j - 1]);
    d = n;
  }
  return d[b.length] / Math.max(1, a.length);
}

export default async function ({ view, call }) {
  if (view !== "editor") return;
  const log = (m) => call("ui_log", { level: m.startsWith("FAIL") ? "error" : "info", message: `check: ${m}` });
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const until = async (f, ms = 8000) => {
    const t0 = performance.now();
    while (performance.now() - t0 < ms) {
      if (f()) return true;
      await wait(100);
    }
    return false;
  };
  let good = 0, bad = 0;
  const ok = async (cond, name, detail = "") => {
    if (cond) good++;
    else bad++;
    await log(`${cond ? "ok" : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`);
  };
  const shot = async (name) => {
    await log(`shot ${name}`);
    await wait(4500);
  };

  if (!(await until(() => window.monetshot, 15000))) return log("FAIL the editor never opened");
  const s = window.monetshot;
  await wait(1500);
  await log(`opened ${s.name}: ${s.takes.length} take(s), voice ${s.takes[0].voice}`);
  await ok(s.speech.hasVoice, "the take has a voice");
  document.querySelector(".inspector .scroll")?.scrollTo?.({ top: 0 });

  // It starts by itself (Transcribe new takes is on by default).
  const began = await until(() => s.speech.busy != null || s.speech.words.length > 0, 15000);
  await ok(began, "transcription starts on open");
  let sawDownload = false, sawListen = false;
  const t0 = performance.now();
  const finished = await until(() => {
    if (s.speech.busy?.stage === "download") sawDownload = true;
    if (s.speech.busy?.stage === "listen" && s.speech.busy.progress > 0) sawListen = true;
    return s.speech.busy == null;
  }, 600000);
  await ok(finished && !s.speech.error, "transcription finishes", `${((performance.now() - t0) / 1000).toFixed(1)} s${s.speech.error ? `: ${s.speech.error}` : ""}`);
  await ok(sawDownload || sawListen, "progress is shown", `download ${sawDownload}, listening ${sawListen}`);
  const t = s.takes[0].transcript;
  const heard = (t?.words ?? []).map((w) => w.text).join(" ");
  const rate = wer(SENTENCE, heard);
  await log(`heard (${t?.language}, ${t?.engine}): ${heard}`);
  await ok(rate <= 0.13, "word error rate", rate.toFixed(3));
  await ok(t?.language === "en" && t?.engine === "whisper", "language and engine", `${t?.language} ${t?.engine}`);
  await ok((t?.words[0]?.start ?? 0) >= 0.45, "times are the take's (voice 0.5 s in)", `first word at ${t?.words[0]?.start}`);
  await ok(s.edit.captions === true, "captions switch on when first heard");
  const words = [...document.querySelectorAll(".transcript .word")];
  await ok(words.length === s.speech.words.length && words.length > 8, "the transcript panel shows the words", `${words.length}`);

  // The caption is in the frame, the word being said lit.
  const w2 = s.speech.words[2];
  s.seek((w2.start + w2.end) / 2);
  await wait(400);
  const plan = s.editor.plan(s.time);
  const cap = plan.texts.find((x) => x.highlight != null);
  await ok(!!cap && cap.lines.join(" ").includes(w2.text), "a caption is planned, the word said lit", cap ? `${cap.lines.join(" / ")} [${cap.highlight}]` : "none");
  await shot("captions-editor");

  // Fix a word: click it, type, Enter; it's saved.
  const first = document.querySelector(".transcript .word");
  first.click();
  await wait(200);
  const input = document.querySelector(".transcript input.fix");
  await ok(!!input, "clicking a word opens its field");
  if (input) {
    input.value = "Monet-Shot";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    await wait(600);
  }
  await ok(s.takes[0].transcript.words[0].text === "Monet-Shot", "the word is fixed", s.takes[0].transcript.words[0].text);
  const back = await call("editor_load", { path: s.folder });
  await ok(back.takes[0].transcript?.words[0]?.text === "Monet-Shot", "transcript.json is saved");
  // Drop a word (empty it).
  const n = s.takes[0].transcript.words.length;
  document.querySelectorAll(".transcript .word")[1].click();
  await wait(200);
  const input2 = document.querySelector(".transcript input.fix");
  if (input2) {
    input2.value = "";
    input2.dispatchEvent(new Event("input", { bubbles: true }));
    input2.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    await wait(600);
  }
  await ok(s.takes[0].transcript.words.length === n - 1, "emptying a word drops it");
  await ok(s.editor.transcriptText().startsWith("Monet-Shot turns") || s.editor.transcriptText().startsWith("Monet-Shot "), "the transcript text follows", s.editor.transcriptText().slice(0, 40));

  // The switch.
  const sw = [...document.querySelectorAll("button[role=switch]")].find((b) => b.getAttribute("aria-label") === "Captions");
  sw?.click();
  await wait(200);
  await ok(s.edit.captions == null && !s.editor.plan(s.time).texts.some((x) => x.highlight != null), "Captions off hides them");
  sw?.click();
  await wait(200);
  await ok(s.edit.captions === true, "Captions on again");
  await s.save();

  // Export: the video, and its subtitles beside it.
  dispatchEvent(new KeyboardEvent("keydown", { key: "e", ctrlKey: true, bubbles: true }));
  const started = await until(() => s.exportProgress != null, 5000);
  await ok(started, "Ctrl+E starts the export");
  const done = await until(() => s.exportProgress == null && (s.exportedPath || s.exportError), 600000);
  await ok(done && !!s.exportedPath, "the export finishes", s.exportedPath ?? s.exportError ?? "");
  await log(`done ${good} ok, ${bad} failed`);
}
