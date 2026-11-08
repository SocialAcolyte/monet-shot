// Browser stand-ins for the app, so pages run in Safari/WebKit for checking
// (`npm run dev`, then open http://localhost:5183/?view=pill). Never loaded
// inside Tauri.
import { mock, mockEmit, type BarState } from "./ipc";
import "../editor/music/mock";

let bar: BarState = {
  phase: { kind: "idle" },
  paused: false,
  pausedTotal: 0,
  pausedSince: null,
  problem: null,
  cameraToo: false,
  vertical: false,
};
let gen = 0;

function set(change: Partial<BarState>) {
  bar = { ...bar, ...change };
  mockEmit("bar", bar);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function countIn(g: number) {
  for (const n of [3, 2, 1]) {
    if (g !== gen) return;
    set({ phase: { kind: "countdown", n } });
    await sleep(1000);
  }
  if (g !== gen) return;
  set({ phase: { kind: "recording", since: Date.now() }, paused: false, pausedTotal: 0, pausedSince: null });
}

mock("bar_state", () => bar);
mock("bar_toggle_vertical", () => set({ vertical: !bar.vertical }));
mock("bar_tap", () => {
  if (bar.phase.kind === "idle") {
    set({ phase: { kind: "picking" }, problem: null });
    const g = ++gen;
    setTimeout(() => countIn(g), 300);
  } else if (bar.phase.kind === "countdown") {
    gen++;
    set({ phase: { kind: "idle" } });
  }
});
mock("bar_cancel", () => {
  gen++;
  set({ phase: { kind: "idle" } });
});
mock("bar_toggle_pause", () => {
  if (bar.phase.kind !== "recording") return;
  const now = Date.now();
  if (bar.paused) {
    set({ paused: false, pausedTotal: bar.pausedTotal + (now - (bar.pausedSince ?? now)), pausedSince: null });
  } else {
    set({ paused: true, pausedSince: now });
  }
});
mock("bar_stop", async () => {
  set({ phase: { kind: "saving" } });
  await sleep(800);
  set({ phase: { kind: "idle" }, paused: false });
});
mock("show_home", () => {});

// ?view=pill&state=recording opens the pill already in that state.
const want = new URLSearchParams(location.search).get("state");
if (want === "recording") bar = { ...bar, phase: { kind: "recording", since: Date.now() - 47_000 } };
if (want === "paused")
  bar = { ...bar, phase: { kind: "recording", since: Date.now() - 47_000 }, paused: true, pausedSince: Date.now() };
if (want === "countdown") bar = { ...bar, phase: { kind: "countdown", n: 2 } };
if (want === "saving") bar = { ...bar, phase: { kind: "saving" } };
if (want === "problem") bar = { ...bar, problem: "Couldn't record" };

// Home: a few recordings, carded with the gallery's paintings.
const repo = __MONETSHOT_REPO__;
const paintings = ["monet-water-lilies", "hokusai-great-wave", "van-gogh-starry-night", "turner-temeraire", "sargent-venice"];
const items = Array.from({ length: 11 }, (_, i) => ({
  path: `/mock/2026-11-0${1 + (i % 3)} ${10 + i}.0${i % 6}.00.reel`,
  title: `${1 + (i % 3)} Nov, ${10 + i}:0${i % 6}`,
  duration: 7 + i * 13,
  clips: 1 + (i % 4),
  takes: 1 + (i % 2),
}));
mock("home_items", () => (new URLSearchParams(location.search).has("empty") ? [] : items));
mock("home_thumb", (a) => {
  const i = items.findIndex((it) => it.path === a?.path);
  return `${repo}/Resources/Backdrops/thumbs/${paintings[i % paintings.length]}.jpg`;
});
mock("open_recording", () => {});

// Editor: ?view=editor&reel=<abs path> loads a real .reel through Vite's /@fs
// (first take only), so the editor runs in a plain browser.
mock("editor_load", async (a) => {
  const folder = String(a?.path);
  const get = async (f: string) => {
    const r = await fetch(`/@fs${folder}/${f}`);
    return r.ok ? r.json() : null;
  };
  const meta = await get("meta.json");
  return {
    folder,
    name: folder.split("/").pop()!.replace(/\.reel$/, ""),
    title: folder.split("/").pop()!.replace(/\.reel$/, ""),
    edit: (await get("edit.json")) ?? {},
    takes: [{ meta, cursor: (await get("cursor.json")) ?? { samples: [], clicks: [] }, dir: "", video: `${folder}/${meta.video ?? "screen.mp4"}`, camera: null }],
  };
});
mock("editor_save", () => {});
mock("backdrop_gallery", () => []);
mock("filmstrip", () => Promise.reject("no filmstrips in the browser"));
