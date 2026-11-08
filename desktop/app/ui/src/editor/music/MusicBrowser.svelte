<script lang="ts">
  // The music browser (MusicBrowserView): a tall charcoal panel docked over
  // the inspector, so your video stays in view. Click a track and it plays
  // under the video itself, from where it would start; the waveform shows
  // the part you hear. Shelves (for this video, favourites, the moods) and
  // tempo up top; a heart keeps a track; Use puts it in the edit.
  import { onDestroy, onMount } from "svelte";
  import { FolderOpen, Search, X, Play, Pause, Heart, Sparkles } from "@lucide/svelte";
  import type { EditorStore } from "../store.svelte";
  import Spinner from "../../components/Spinner.svelte";
  import Artwork from "./Artwork.svelte";
  import TrackWave from "./TrackWave.svelte";
  import { call, inTauri } from "../../lib/ipc";
  import {
    clock,
    library,
    loadFavourites,
    moods,
    saveFavourites,
    stopAudition,
    suggestions,
    tempos,
    toggleAudition,
    useMusic,
    type Song,
    type Tempo,
  } from "./music";

  let { store }: { store: EditorStore } = $props();

  type Shelf = { kind: "suggested" } | { kind: "favourites" } | { kind: "mood"; id: string };
  let query = $state("");
  // A format's "Find … music" opens on its mood; otherwise on this video's picks.
  let shelf = $state<Shelf>(store.musicMood && moods.some((m) => m.id === store.musicMood) ? { kind: "mood", id: store.musicMood } : { kind: "suggested" });
  let tempo = $state<Tempo | null>(null);
  let tracks = $state<Song[]>([]);
  let loading = $state(false);
  let problem = $state<string | null>(null);
  let favourites = $state<string[]>(loadFavourites());
  /** The track being copied into the recording. */
  let adding = $state<string | null>(null);

  const tempoOf = (s: Song): string | undefined => store.c.musicTempo(s) ?? undefined;

  let generation = 0;
  async function reload() {
    const gen = ++generation;
    loading = true;
    problem = null;
    try {
      let r: Song[];
      if (query.trim()) r = await library(query, null);
      else if (shelf.kind === "suggested") r = await suggestionsFor();
      else if (shelf.kind === "favourites") r = (await library("", null)).filter((s) => favourites.includes(s.id));
      else r = await library("", shelf.id);
      if (tempo && !(shelf.kind === "suggested" && !query.trim())) r = r.filter((s) => tempoOf(s) === tempo);
      if (gen === generation) tracks = r;
    } catch (e) {
      if (gen === generation) problem = "The music library isn't here. Reinstall Monet Shot to get it back.";
      console.error("music", e);
    }
    if (gen === generation) loading = false;
  }

  /** This video's picks, within the tempo when one is chosen. */
  async function suggestionsFor(): Promise<Song[]> {
    if (!tempo) return suggestions(store, favourites);
    const all = (await library("", null)).filter((s) => tempoOf(s) === tempo);
    const picked = await suggestions(store, favourites);
    // the ranked picks in this tempo first, then the rest of the tempo
    return [...picked.filter((s) => tempoOf(s) === tempo), ...all.filter((s) => !picked.some((p) => p.id === s.id))].slice(0, 8);
  }

  let typing = 0;
  function setQuery(q: string) {
    query = q;
    clearTimeout(typing);
    typing = window.setTimeout(reload, 200); // wait for typing to pause
  }

  function show(s: Shelf) {
    shelf = s;
    query = "";
    reload();
  }

  function setTempo(t: Tempo) {
    tempo = tempo === t ? null : t;
    reload();
  }

  function toggleFavourite(t: Song) {
    favourites = favourites.includes(t.id) ? favourites.filter((x) => x !== t.id) : [...favourites, t.id];
    saveFavourites(favourites);
    if (shelf.kind === "favourites" && !query) reload();
  }

  async function use(t: Song) {
    if (adding) return;
    adding = t.id;
    const ok = await useMusic(store, t);
    adding = null;
    if (!ok) problem = "Couldn't add that track.";
  }

  /** Music you've licensed elsewhere (a file on this computer). */
  async function ownFile() {
    if (!inTauri) return;
    const { open } = await import("@tauri-apps/plugin-dialog");
    const path = await open({
      title: "Choose a music file you have the rights to use",
      filters: [{ name: "Audio", extensions: ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "aif"] }],
    });
    if (typeof path !== "string") return;
    try {
      use(await call<Song>("music_own_file", { path }));
    } catch (e) {
      problem = String(e);
    }
  }

  function keys(e: KeyboardEvent) {
    // (Esc closes: the editor's own keys do that.)
    if (e.key === " " && store.audition && !(e.target instanceof HTMLInputElement)) {
      // Space pauses or goes on with the track under the video.
      e.preventDefault();
      store.togglePlay();
    }
  }

  /** The stretch of a track that plays under this video, as fractions of it. */
  function partOf(t: Song): [number, number] | null {
    const len = store.duration;
    if (!(t.duration > 0) || !(len > 0)) return null;
    const a = store.audition;
    const start = a && a.track.id === t.id ? a.offset : store.c.musicPlace(t.grid ?? null, t.duration, len, t.start, store.isVertical).offset;
    return [Math.min(1, start / t.duration), Math.min(1, (start + len) / t.duration)];
  }

  onMount(reload);
  onDestroy(() => stopAudition(store));

  const heading = $derived(
    query ? "Results" : shelf.kind === "suggested" ? "For this video" : shelf.kind === "favourites" ? "Favourites" : (moods.find((m) => m.id === (shelf as { id: string }).id)?.name ?? "Music"),
  );
  const subheading = $derived.by(() => {
    if (query) return null;
    if (shelf.kind === "suggested") return store.isVertical ? `Punchier picks for a ${clock(store.duration)} vertical video` : `Picked for a ${clock(store.duration)} video`;
    if (shelf.kind === "favourites" && !favourites.length) return "Tap the heart on a track to keep it here";
    return null;
  });
  const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
  const detail = (t: Song) => [t.artist, t.genres[0] ? cap(t.genres[0]) : "", tempoOf(t) ? cap(tempoOf(t)!) : ""].filter(Boolean).join(" · ");
  const auditioning = $derived(store.audition?.track as Song | undefined);
  const at = $derived(auditioning && auditioning.duration > 0 ? Math.min(1, ((store.audition?.offset ?? 0) + store.time) / auditioning.duration) : null);
</script>

<svelte:window onkeydown={keys} />

<div class="panel" role="dialog" aria-label="Music">
  <header>
    <div class="titles">
      <div>
        <h1>Music</h1>
        <p>Free to use anywhere: no credit, no conditions</p>
      </div>
      <span class="spacer"></span>
      <button class="pill-button" onclick={ownFile} title="Music you've licensed elsewhere (Artlist, Epidemic, your own)">
        <FolderOpen /> Your own
      </button>
      <button class="close" onclick={() => store.closeMusic()} aria-label="Close (Esc)"><X size={13} strokeWidth={3} /></button>
    </div>
    <label class="search">
      <Search size={15} />
      <input placeholder="Songs, artists, moods" value={query} oninput={(e) => setQuery(e.currentTarget.value)} />
      {#if loading}<Spinner />{/if}
    </label>
    <div class="chips shelves">
      <button class="chip" class:on={!query && shelf.kind === "suggested"} onclick={() => show({ kind: "suggested" })}><Sparkles size={11} /> For this video</button>
      <button class="chip" class:on={!query && shelf.kind === "favourites"} onclick={() => show({ kind: "favourites" })}><Heart size={11} /> Favourites</button>
      {#each moods as m (m.id)}
        <button class="chip" class:on={!query && shelf.kind === "mood" && shelf.id === m.id} onclick={() => show({ kind: "mood", id: m.id })}>
          <i class="dot" style:background={m.tint}></i>{m.name}
        </button>
      {/each}
    </div>
    <div class="chips">
      <span class="label">Tempo</span>
      {#each tempos as t (t)}
        <button class="chip" class:on={tempo === t} onclick={() => setTempo(t)}>{cap(t)}</button>
      {/each}
    </div>
  </header>

  <div class="scroll">
    <h2>{heading}</h2>
    {#if subheading}<p class="sub-heading">{subheading}</p>{/if}

    {#if problem && !tracks.length}
      <p class="empty">{problem}</p>
    {:else if !tracks.length && !loading && !(shelf.kind === "favourites" && !query)}
      <p class="empty">Nothing here. Try another word or tempo.</p>
    {/if}

    <ol>
      {#each tracks as t (t.id)}
        {@const current = auditioning?.id === t.id}
        {@const fav = favourites.includes(t.id)}
        <li class:current title={t.about ?? ""}>
          <div class="line">
            <button class="row" onclick={() => toggleAudition(store, t)} aria-label="Play {t.title} under the video">
              <span class="cover">
                <Artwork song={t} size={42} />
                {#if current}
                  <span class="veil">
                    {#if store.playing}<span class="eq"><i></i><i></i><i></i></span>{:else}<Play size={13} fill="currentColor" />{/if}
                  </span>
                {/if}
              </span>
              <span class="text">
                <span class="title">{t.title}</span>
                <span class="sub">{detail(t)}</span>
              </span>
              <span class="len tabular">{clock(t.duration)}</span>
            </button>
            <button class="heart" class:fav onclick={() => toggleFavourite(t)} aria-label={fav ? "Remove from favourites" : "Keep in favourites"} title={fav ? "Remove from favourites" : "Keep in favourites"}>
              <Heart size={14} fill={fav ? "currentColor" : "none"} />
            </button>
            <button class="pill-button" class:prominent={current} disabled={adding != null} onclick={() => use(t)}>
              {#if adding === t.id}<Spinner />{:else}Use{/if}
            </button>
          </div>
          <TrackWave peaks={t.peaks ?? []} part={partOf(t)} at={current ? at : null} lit={current} />
        </li>
      {/each}
    </ol>
  </div>

  {#if auditioning}
    <footer>
      <button class="play" onclick={() => store.togglePlay()} aria-label={store.playing ? "Pause" : "Play"}>
        {#if store.playing}<Pause size={14} fill="currentColor" />{:else}<Play size={14} fill="currentColor" />{/if}
      </button>
      <span class="text">
        <span class="title">{auditioning.title}</span>
        <span class="sub">Playing under your video</span>
      </span>
      <span class="spacer"></span>
      <button class="pill-button prominent" disabled={adding != null} onclick={() => auditioning && use(auditioning)}>
        {#if adding === auditioning.id}<Spinner /> Adding{:else}Use this track{/if}
      </button>
    </footer>
  {/if}
</div>

<style>
  .panel {
    position: fixed;
    z-index: 51;
    top: 12px;
    bottom: 12px;
    right: 12px;
    width: min(452px, calc(100vw - 24px));
    display: flex;
    flex-direction: column;
    background: var(--panel);
    color: var(--moon-white);
    border-radius: 16px;
    box-shadow:
      0 0 0 1px rgba(255, 255, 255, 0.07),
      -6px 10px 60px rgba(0, 0, 0, 0.45);
    overflow: hidden;
    animation: slide var(--dur-base) var(--ease-base);
  }
  @keyframes slide {
    from {
      opacity: 0;
      transform: translateX(24px);
    }
  }
  header {
    padding: 20px 20px 12px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .titles {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  h1 {
    margin: 0;
    font-size: 24px;
    font-weight: 700;
  }
  .titles p {
    margin: 3px 0 0;
    font-size: 11.5px;
    color: var(--faint);
  }
  .spacer {
    flex: 1;
  }
  .close {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: var(--midnight);
    display: grid;
    place-items: center;
  }
  .search {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 34px;
    padding: 0 13px;
    border-radius: 17px;
    background: var(--midnight);
    color: var(--dim);
  }
  .search input {
    flex: 1;
    border: 0;
    outline: 0;
    background: transparent;
    color: var(--moon-white);
    font: inherit;
    font-size: 13.5px;
  }
  .chips {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .shelves {
    overflow-x: auto;
    scrollbar-width: none;
  }
  .shelves::-webkit-scrollbar {
    display: none;
  }
  .label {
    font-size: 11px;
    font-weight: 600;
    color: var(--faint);
    margin-right: 4px;
  }
  .chip {
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    height: 26px;
    padding: 0 11px;
    border-radius: 13px;
    background: var(--midnight);
    color: color-mix(in srgb, var(--moon-white) 85%, transparent);
    font-size: 12px;
    font-weight: 600;
    white-space: nowrap;
    transition:
      background var(--dur-snappy) var(--ease-snappy),
      color var(--dur-snappy) var(--ease-snappy);
  }
  .chip.on {
    background: var(--moon-white);
    color: var(--charcoal);
  }
  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
  }
  .scroll {
    flex: 1;
    overflow-y: auto;
    padding: 0 14px 18px;
    scrollbar-width: none;
  }
  .scroll::-webkit-scrollbar {
    display: none;
  }
  h2 {
    margin: 4px 6px 2px;
    font-size: 17px;
    font-weight: 700;
  }
  .sub-heading {
    margin: 0 6px 8px;
    font-size: 11.5px;
    color: var(--dim);
  }
  .empty {
    margin: 30px 6px;
    font-size: 13px;
    color: var(--dim);
  }
  ol {
    list-style: none;
    margin: 8px 0 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  li {
    display: flex;
    flex-direction: column;
    gap: 7px;
    padding: 8px;
    border-radius: 10px;
    transition: background var(--dur-snappy) var(--ease-snappy);
  }
  li.current {
    background: var(--midnight);
  }
  .line {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .row {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 12px;
    text-align: left;
  }
  .cover {
    position: relative;
    width: 42px;
    height: 42px;
    flex: none;
  }
  .veil {
    position: absolute;
    inset: 0;
    border-radius: 6px;
    background: rgba(0, 0, 0, 0.45);
    display: grid;
    place-items: center;
  }
  .text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .title {
    font-size: 13.5px;
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .current .title {
    color: var(--violet);
  }
  .sub {
    font-size: 11.5px;
    color: var(--dim);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .len {
    font-size: 11.5px;
    color: var(--faint);
  }
  .heart {
    width: 24px;
    height: 24px;
    display: grid;
    place-items: center;
    color: var(--faint);
  }
  .heart.fav {
    color: var(--clay, #c96f4a);
  }
  li :global(.wave) {
    margin-left: 54px;
  }
  .eq {
    display: inline-flex;
    align-items: flex-end;
    gap: 2px;
    height: 14px;
  }
  .eq i {
    width: 3px;
    border-radius: 1.5px;
    background: var(--violet);
    animation: eq 0.6s ease-in-out infinite alternate;
  }
  .eq i:nth-child(2) {
    animation-duration: 0.45s;
  }
  .eq i:nth-child(3) {
    animation-duration: 0.7s;
  }
  @keyframes eq {
    from {
      height: 5px;
    }
    to {
      height: 14px;
    }
  }
  footer {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 62px;
    padding: 0 16px;
    background: var(--charcoal);
    animation: up var(--dur-base) var(--ease-base);
  }
  @keyframes up {
    from {
      transform: translateY(100%);
      opacity: 0;
    }
  }
  .play {
    width: 34px;
    height: 34px;
    border-radius: 50%;
    background: var(--moon-white);
    color: var(--charcoal);
    display: grid;
    place-items: center;
  }
  @media (prefers-reduced-motion: reduce) {
    .eq i {
      animation: none;
      height: 9px;
    }
  }
</style>
