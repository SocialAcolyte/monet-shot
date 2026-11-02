<script lang="ts">
  // The inspector's Camera section: how the bubble looks, the camera clips,
  // and "Record yourself".
  import { CircleUserRound, RectangleHorizontal, Trash2 } from "@lucide/svelte";
  import type { EditorStore } from "../store.svelte";
  import Section from "../parts/Section.svelte";
  import ToggleRow from "../parts/ToggleRow.svelte";
  import SliderRow from "../parts/SliderRow.svelte";
  import Segmented from "../parts/Segmented.svelte";
  import Hint from "../parts/Hint.svelte";
  import CornerPicker from "./CornerPicker.svelte";
  import { stamp, percent } from "../format";

  let { store }: { store: EditorStore } = $props();

  const look = $derived(store.edit.cameraLook);
  const set = <K extends keyof typeof look>(key: K, v: (typeof look)[K]) => store.update((e) => (e.cameraLook[key] = v));
</script>

<Section title="Camera">
  {#if store.hasCamera}
    <ToggleRow label="Show camera" on={look.visible} onchange={(v) => set("visible", v)} />
    {#if look.visible}
      <div class="shape">
        <Segmented
          options={[
            { value: "circle", label: "Circle" },
            { value: "rounded", label: "Rounded" },
          ]}
          value={look.shape}
          onchange={(v) => set("shape", v)}
        />
        <CornerPicker corner={look.corner} onchange={(c) => set("corner", c)} />
      </div>
      <SliderRow label="Size" value={look.size} min={0.14} max={0.5} format={percent} onchange={(v) => set("size", v)} />
      <ToggleRow label="Mirror" on={look.mirror} onchange={(v) => set("mirror", v)} />
      {#if store.edit.music}
        <ToggleRow label="Lower music while you talk" on={look.duckMusic} onchange={(v) => set("duckMusic", v)} />
      {/if}
    {/if}
    {#each store.edit.cameraClips as c (c.id)}
      <div class="clip">
        {#if c.full}<RectangleHorizontal size={14} />{:else}<CircleUserRound size={14} />{/if}
        <button class="times tabular" onclick={() => store.seek(c.at + 0.05)}>{stamp(c.at)} – {stamp(c.at + c.duration)}</button>
        <span class="spacer"></span>
        <button class="pill-button" title="Fill the frame with you, or sit in the bubble" onclick={() => store.setCameraClip(c.id, (x) => (x.full = !x.full))}>
          {c.full ? "Full" : "Bubble"}
        </button>
        <button class="pill-button" title="Delete this camera clip" aria-label="Delete this camera clip" onclick={() => store.deleteCameraClip(c.id)}>
          <Trash2 />
        </button>
      </div>
    {/each}
  {:else}
    <Hint text="Talk over the video as it plays, or record a clip of just you." />
  {/if}
  <button class="pill-button wide" onclick={() => store.openCamera()}><CircleUserRound /> Record yourself</button>
</Section>

<style>
  .shape {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .shape > :global(:first-child) {
    flex: 1;
  }
  .clip {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--violet);
  }
  .times {
    font-size: 12px;
    color: var(--moon-white);
  }
  .spacer {
    flex: 1;
  }
  .wide {
    justify-content: center;
    width: 100%;
  }
</style>
