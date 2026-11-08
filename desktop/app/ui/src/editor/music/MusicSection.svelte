<script lang="ts">
  // The inspector's Music section: the track, which part of it plays, level
  // and fades, the credit when its licence asks for one, change or remove.
  import { Music, ListMusic, Trash2, Copy } from "@lucide/svelte";
  import type { EditorStore } from "../store.svelte";
  import Section from "../parts/Section.svelte";
  import SliderRow from "../parts/SliderRow.svelte";
  import ToggleRow from "../parts/ToggleRow.svelte";
  import Artwork from "./Artwork.svelte";
  import SnippetPicker from "./SnippetPicker.svelte";
  import { percent } from "../format";
  import { copyCredit, licenseLabel, loadShape, needsCredit, refreshVoice, removeMusic, type Song } from "./music";

  let { store }: { store: EditorStore } = $props();

  const m = $derived(store.edit.music ?? null);
  const track = $derived(m?.track as Song | undefined);

  // The wave and the beat grid, read once per music file.
  $effect(() => {
    void store.edit.music?.file;
    loadShape(store);
  });

  // Where the music ducks: re-read when the voices or the cut change.
  $effect(() => {
    void store.edit.music?.file;
    void store.edit.cameraClips;
    void store.edit.cameraLook.duckMusic;
    void store.version;
    refreshVoice(store, 600);
  });

  let copied = $state(false);
  async function credit() {
    await copyCredit(store);
    copied = true;
    setTimeout(() => (copied = false), 1600);
  }
</script>

<Section title="Music">
  {#if m && track}
    <div class="track">
      <Artwork song={track} size={40} />
      <div class="text">
        <span class="title">{track.title}</span>
        <span class="sub">{track.artist} · {licenseLabel(track)}</span>
      </div>
    </div>
    <SnippetPicker {store} music={m} />
    <SliderRow label="Volume" value={m.volume} min={0} max={1} format={percent} onchange={(v) => store.setMusic((x) => (x.volume = v))} />
    <ToggleRow label="Fade in" on={m.fadeIn} onchange={(v) => store.setMusic((x) => (x.fadeIn = v))} />
    <ToggleRow label="Fade out" on={m.fadeOut} onchange={(v) => store.setMusic((x) => (x.fadeOut = v))} />
    {#if needsCredit(track)}
      <button class="credit" onclick={credit} title="This licence asks for a credit; it's also saved beside every export">
        <Copy size={12} />
        {copied ? "Copied" : "Copy credit"}
      </button>
    {/if}
    <div class="actions">
      <button class="pill-button" onclick={() => store.openMusic()}><ListMusic /> Change</button>
      <button class="pill-button" onclick={() => removeMusic(store)}><Trash2 /> Remove</button>
    </div>
  {:else}
    <button class="pill-button wide" onclick={() => store.openMusic()}><Music /> Add music</button>
  {/if}
</Section>

<style>
  .track {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .text {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .title {
    font-size: 12.5px;
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .sub {
    font-size: 11px;
    color: var(--dim);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .credit {
    align-self: flex-start;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 11.5px;
    font-weight: 500;
    color: var(--violet);
  }
  .actions {
    display: flex;
    gap: 8px;
  }
  .wide {
    justify-content: center;
    width: 100%;
  }
</style>
