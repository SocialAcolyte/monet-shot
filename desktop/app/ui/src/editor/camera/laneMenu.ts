// Right-click on a camera clip in the timeline (the Mac's context menu).
import type { EditorStore } from "../store.svelte";
import { inTauri } from "../../lib/ipc";

export async function laneMenu(store: EditorStore, clipId: string, e: MouseEvent) {
  e.preventDefault();
  const clip = store.edit.cameraClips.find((c) => c.id === clipId);
  if (!clip || !inTauri) return;
  const { Menu, MenuItem } = await import("@tauri-apps/api/menu");
  const m = await Menu.new({
    items: [
      await MenuItem.new({
        text: clip.full ? "Show in the bubble" : "Fill the frame",
        action: () => store.setCameraClip(clipId, (c) => (c.full = !c.full)),
      }),
      await MenuItem.new({ text: "Delete", action: () => store.deleteCameraClip(clipId) }),
    ],
  });
  await m.popup();
}
