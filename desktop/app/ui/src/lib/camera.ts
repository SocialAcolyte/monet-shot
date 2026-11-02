// The camera's live picture, from the app (the page never opens the camera:
// it's exclusive on Linux and Windows). Frames are JPEGs at ~30 fps; one
// object URL is live at a time, the previous one is revoked once the next
// has decoded, so memory stays flat.
import { inTauri } from "./ipc";

export async function watchCamera(onUrl: (url: string) => void): Promise<() => void> {
  if (!inTauri) return () => {};
  const { Channel, invoke } = await import("@tauri-apps/api/core");
  let live: string | null = null;
  let busy = false;
  let stopped = false;
  const ch = new Channel<ArrayBuffer>();
  ch.onmessage = (buf) => {
    // Drop frames while the last is still decoding rather than queueing them.
    if (stopped || busy) return;
    busy = true;
    const url = URL.createObjectURL(new Blob([buf], { type: "image/jpeg" }));
    const img = new Image();
    img.onload = img.onerror = () => {
      busy = false;
      if (stopped) return URL.revokeObjectURL(url);
      const old = live;
      live = url;
      onUrl(url);
      if (old) requestAnimationFrame(() => URL.revokeObjectURL(old));
    };
    img.src = url;
  };
  await invoke("camera_preview", { channel: ch });
  return () => {
    stopped = true;
    if (live) URL.revokeObjectURL(live);
  };
}
