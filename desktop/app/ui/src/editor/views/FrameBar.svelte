<script lang="ts">
  // Replaces the transport while framing (FrameBar).
  import { Play, Pause, EyeOff, Crop, Trash2 } from "@lucide/svelte";
  import Segmented from "../parts/Segmented.svelte";
  import type { EditorStore } from "../store.svelte";
  import { stamp } from "../format";

  let { store }: { store: EditorStore } = $props();
  const crop = $derived(store.crop(store.framingTake));
  const full = $derived(crop.x === 0 && crop.y === 0 && crop.w === 1 && crop.h === 1);
</script>

<div class="bar">
  <button class="pill-button prominent" onclick={() => store.closeFraming()} title="Back to the finished look (Esc)">Done</button>
  <button class="pill-button" onclick={() => store.togglePlay()} title="Play / Pause (Space)" aria-label={store.playing ? "Pause" : "Play"}>
    {#if store.playing}<Pause fill="currentColor" />{:else}<Play fill="currentColor" />{/if}
  </button>
  <span class="time tabular">{stamp(store.time)} / {stamp(store.duration)}</span>
  <Segmented
    fit
    options={[{ value: "blur" as const, label: "Hide", icon: EyeOff }, { value: "crop" as const, label: "Crop", icon: Crop }]}
    value={store.frameTool}
    onchange={(v) => (store.frameTool = v)}
  />
  <span class="spacer"></span>
  <span class="hint">{store.frameTool === "crop" ? "Drag the edges to keep only part of the screen." : "Drag over anything you don't want seen."}</span>
  {#if store.frameTool === "crop"}
    <button class="pill-button" disabled={full} onclick={() => store.resetCrop()} title="Show the whole recording again">Reset</button>
  {:else if store.selectedBlur}
    {@const b = store.selectedBlur}
    <button class="pill-button" onclick={() => store.deleteBlur(b.id)} title="Stop hiding this (Delete)"><Trash2 /> Remove</button>
  {/if}
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
  .hint {
    font-size: 11.5px;
    color: var(--dim);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }
</style>
