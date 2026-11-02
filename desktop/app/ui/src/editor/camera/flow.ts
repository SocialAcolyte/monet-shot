// Recording yourself in the editor (owner: ms-capture). Ported from the
// camera part of the Mac's EditorModel: open the camera, 3-2-1, then either
// talk over the edit as it plays muted from the playhead (a camera clip in
// output time) or record a clip of just you (a new take at the end).
import type { CameraPhase, EditorStore } from "../store.svelte";
import type { CameraClip } from "../core";
import { call, inTauri } from "../../lib/ipc";
import { cameraUi, type Device } from "./state.svelte";

interface Recorded {
  file: string;
  duration: number;
}

interface Session {
  /** The 3-2-1 that's running, cancelled by flipping this. */
  countdown: { cancelled: boolean } | null;
  /** The file being recorded and the output time it started at. */
  take: { file: string; at: number } | null;
}

const sessions = new WeakMap<EditorStore, Session>();
const session = (s: EditorStore) => {
  let x = sessions.get(s);
  if (!x) sessions.set(s, (x = { countdown: null, take: null }));
  return x;
};

/** Each editor holds the shared camera under its own name. */
const owner = (s: EditorStore) => `editor:${s.folder}`;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function openCamera(store: EditorStore) {
  if (store.playing) store.togglePlay();
  if (store.cameraPhase.kind !== "off") return;
  store.cameraPhase = { kind: "ready" };
  const ok = inTauri ? await call<boolean>("camera_open", { owner: owner(store) }) : true;
  if (!ok) {
    store.cameraPhase = { kind: "off" };
    await cantUseCamera();
    return;
  }
  loadDevices();
}

export function closeCamera(store: EditorStore) {
  const s = session(store);
  if (s.countdown) s.countdown.cancelled = true;
  if (store.cameraPhase.kind === "recording") {
    stopCamera(store).then(() => release(store));
    return;
  }
  if (store.cameraPhase.kind === "off") return;
  store.cameraPhase = { kind: "off" };
  release(store);
}

/** Space in camera mode: count in, cancel the count, or stop. */
export function toggleCameraRecording(store: EditorStore) {
  const p = store.cameraPhase;
  if (p.kind === "ready") startCamera(store);
  else if (p.kind === "countdown") {
    const s = session(store);
    if (s.countdown) s.countdown.cancelled = true;
    store.cameraPhase = { kind: "ready" };
  } else if (p.kind === "recording") stopCamera(store);
}

/** 3, 2, 1, then the camera records while the edit plays (muted, so the
 *  microphone hears only you) from the playhead. */
async function startCamera(store: EditorStore) {
  if (store.cameraPhase.kind !== "ready") return;
  const s = session(store);
  const count = { cancelled: false };
  s.countdown = count;
  for (const n of [3, 2, 1]) {
    store.cameraPhase = { kind: "countdown", n };
    await sleep(800);
    if (count.cancelled) return;
  }
  s.countdown = null;
  const file = `camera-${Math.floor(Date.now() / 1000)}.mp4`;
  const alone = store.cameraAlone;
  if (!alone && store.time >= store.duration - 0.3) store.seek(0);
  const at = store.time;
  try {
    await call("camera_record", { folder: store.folder, file });
  } catch (e) {
    console.error("camera: could not start recording", e);
    store.cameraPhase = { kind: "ready" };
    return;
  }
  // Closed during the start: throw the file away.
  // (The phase can have changed while awaiting.)
  if (count.cancelled || (store.cameraPhase as CameraPhase).kind === "off") {
    const r = await call<Recorded | null>("camera_stop");
    if (r) call("recording_remove_file", { folder: store.folder, name: r.file });
    return;
  }
  s.take = { file, at };
  store.cameraPhase = { kind: "recording", since: Date.now() };
  if (!alone) {
    store.muted = true;
    if (!store.playing) store.togglePlay();
  }
}

async function stopCamera(store: EditorStore) {
  const s = session(store);
  const take = s.take;
  if (store.cameraPhase.kind !== "recording" || !take) return;
  s.take = null;
  store.cameraPhase = { kind: "saving" };
  if (store.playing) store.togglePlay();
  store.muted = false;
  let r: Recorded | null = null;
  try {
    r = await call<Recorded | null>("camera_stop");
  } catch (e) {
    console.error("camera stop", e);
  }
  if (!r) {
    store.cameraPhase = { kind: "ready" };
    return;
  }
  if (store.cameraAlone) {
    // A clip of its own: a new take at the end, framed like the rest.
    try {
      await call("camera_take", { folder: store.folder, file: r.file });
      await store.takesAdded({ zooms: false });
    } catch (e) {
      console.error("camera take", e);
    }
  } else if (r.duration > 0.3) {
    const clip: CameraClip = { id: store.c.newId(), file: r.file, at: take.at, duration: Math.min(r.duration, store.duration - take.at), full: false };
    store.update((e) => (e.cameraClips = store.c.cameraInsert(clip, e.cameraClips)));
    store.seek(take.at);
  } else {
    call("recording_remove_file", { folder: store.folder, name: r.file });
  }
  store.cameraPhase = { kind: "ready" };
  closeCamera(store);
}

function release(store: EditorStore) {
  if (inTauri) call("camera_close", { owner: owner(store) });
}

async function loadDevices() {
  if (!inTauri) return;
  try {
    const d = await call<{ cameras: Device[]; microphones: Device[]; camera: string | null; mic: string | null }>("camera_devices");
    Object.assign(cameraUi, d);
  } catch (e) {
    console.error("camera devices", e);
  }
}

/** The camera menu in the CameraBar. */
export async function useCamera(id: string) {
  cameraUi.camera = id;
  try {
    await call("camera_use", { camera: id, mic: cameraUi.mic });
  } catch (e) {
    console.error("camera use", e);
  }
}

/** As the Mac's alert: say so plainly; there's no settings page to send people to here. */
async function cantUseCamera() {
  const text =
    "Monet Shot couldn't start the camera. Check that one is connected and that no other app is using it" +
    (navigator.userAgent.includes("Linux") ? " (on Linux, your user needs access to /dev/video*)." : ".");
  if (!inTauri) return alert(text);
  const { message } = await import("@tauri-apps/plugin-dialog");
  await message(text, { title: "Monet Shot can't use the camera", kind: "warning" });
}
