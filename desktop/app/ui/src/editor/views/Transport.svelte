<script lang="ts">
  // Under the preview: play, the time in the finished video, and the
  // editor's main actions (TransportBar).
  import { Play, Pause, ScanSearch, CopyPlus, CircleUserRound, Music, EyeOff, Scissors, Plus } from "@lucide/svelte";
  import type { EditorStore } from "../store.svelte";
  import { stamp } from "../format";
  import { inTauri } from "../../lib/ipc";

  let { store, addFootage }: { store: EditorStore; addFootage: () => void } = $props();

  async function addClipMenu(e: MouseEvent) {
    if (!inTauri) return;
    const { Menu, MenuItem } = await import("@tauri-apps/api/menu");
    const { LogicalPosition } = await import("@tauri-apps/api/dpi");
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const m = await Menu.new({
      items: [
        await MenuItem.new({ text: "Record a new take", action: () => store.recordTake() }),
        await MenuItem.new({ text: "Add a video or recording…", action: addFootage }),
      ],
    });
    await m.popup(new LogicalPosition(r.left, r.bottom + 4));
  }
</script>

<div class="bar">
  <button class="pill-button" onclick={() => store.togglePlay()} title="Play / Pause (Space)" aria-label={store.playing ? "Pause" : "Play"}>
    {#if store.playing}<Pause fill="currentColor" />{:else}<Play fill="currentColor" />{/if}
  </button>

  <!-- Times in the finished video: trims and cuts already taken out. -->
  <span class="time tabular">{stamp(store.time)} / {stamp(store.duration)}</span>

  <span class="spacer"></span>

  <button class="pill-button" onclick={() => store.reAuto()} aria-label="Auto zoom" title="Zoom in on every cluster of clicks (keeps zooms you made by hand)">
    <ScanSearch />
  </button>
  <button class="pill-button" onclick={addClipMenu} title="Add footage at the end: record another take, or bring in a video">
    <CopyPlus /> Add clip
  </button>
  <button class="pill-button" onclick={() => store.openCamera()} title="Record yourself, over the video or on your own (C)">
    <CircleUserRound /> Camera
  </button>
  <button class="pill-button" onclick={() => store.openMusic()} title="Add music (M)"><Music /> Music</button>
  <button class="pill-button" onclick={() => store.openFraming()} title="Blur parts of the screen, or crop it (B)"><EyeOff /> Hide</button>
  <button class="pill-button" onclick={() => store.split()} title="Split the clip at the playhead (S)"><Scissors /> Split</button>
  <button class="pill-button" onclick={() => store.addZoom()} title="Add a zoom at the playhead (Z)"><Plus /> Zoom</button>
</div>

<style>
  .bar {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .spacer {
    flex: 1;
  }
  .time {
    font-size: 12px;
    font-weight: 500;
    color: var(--dim);
    white-space: nowrap;
  }
</style>
