<script lang="ts">
  // The music browser (MusicBrowserView): a tall charcoal panel over the
  // editor, in the manner of a streaming app. Search and mood tiles up top,
  // the album-art list, and a now-playing bar with "Use this track".
  import { onDestroy, onMount } from "svelte";
  import { FolderOpen, Search, X, Play, Pause } from "@lucide/svelte";
  import type { EditorStore } from "../store.svelte";
  import Spinner from "../../components/Spinner.svelte";
  import Artwork from "./Artwork.svelte";
  import { call, inTauri } from "../../lib/ipc";
  import { clock, library, licenseLabel, moods, playable, useMusic, type Mood, type Song } from "./music";

  let { store }: { store: EditorStore } = $props();

  let query = $state("");
  let mood = $state<Mood | null>(moods[0]);
  let tracks = $state<Song[]>([]);
  let loading = $state(false);
  let problem = $state<string | null>(null);
  let previewing = $state<Song | null>(null);
  let playing = $state(false);
  let progress = $state(0);
  /** The track being copied into the recording. */
  let adding = $state<string | null>(null);

  const player = new Audio();
  player.ontimeupdate = () => (progress = previewing && previewing.duration > 0 ? Math.min(1, player.currentTime / previewing.duration) : 0);
  player.onended = () => (playing = false);

  let generation = 0;
  async function reload() {
    const gen = ++generation;
    loading = true;
    problem = null;
    try {
      const r = await library(query, query.trim() ? null : (mood?.feel ?? null));
      if (gen === generation) tracks = r;
    } catch (e) {
      if (gen === generation) problem = "The music library isn't here. Reinstall Monet Shot to get it back.";
      console.error("music", e);
    }
    if (gen === generation) loading = false;
  }

  let typing = 0;
  function setQuery(q: string) {
    query = q;
    if (q) mood = null;
    else if (!mood) mood = moods[0];
    clearTimeout(typing);
    typing = window.setTimeout(reload, 200); // wait for typing to pause
  }

  function choose(m: Mood) {
    mood = m;
    query = "";
    reload();
  }

  async function togglePreview(t: Song) {
    if (previewing?.id === t.id) {
      if (playing) player.pause();
      else player.play();
      playing = !playing;
      return;
    }
    const src = await playable(t.audioURL, true);
    if (!src) return;
    previewing = t;
    progress = 0;
    player.src = src;
    player.play().catch((e) => console.error("preview", e));
    playing = true;
  }

  function seekPreview(e: MouseEvent) {
    if (!previewing) return;
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const f = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
    player.currentTime = previewing.duration * f;
    progress = f;
  }

  async function use(t: Song) {
    if (adding) return;
    adding = t.id;
    player.pause();
    playing = false;
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
    // Space previews the current track unless typing in the search.
    if (e.key === " " && previewing && !(e.target instanceof HTMLInputElement)) {
      e.preventDefault();
      togglePreview(previewing);
    }
  }

  onMount(reload);
  onDestroy(() => {
    player.pause();
    player.src = "";
  });

  const heading = $derived(query ? "Results" : (mood?.name ?? "Instrumental"));
  const detail = (t: Song) => [t.genres.slice(0, 2).join(", "), t.bpm ? `${t.bpm} bpm` : ""].filter(Boolean).join(" · ");
</script>

<svelte:window onkeydown={keys} />

<div class="scrim" role="presentation" onclick={() => store.closeMusic()}></div>
<div class="panel" role="dialog" aria-label="Music">
  <header>
    <div class="titles">
      <div>
        <h1>Music</h1>
        <p>Free to use anywhere: no credit, no conditions</p>
      </div>
      <span class="spacer"></span>
      <button class="pill-button" onclick={ownFile} title="Music you've licensed elsewhere (Artlist, Epidemic, your own)">
        <FolderOpen /> Use your own
      </button>
      <button class="close" onclick={() => store.closeMusic()} aria-label="Close (Esc)"><X size={13} strokeWidth={3} /></button>
    </div>
    <label class="search">
      <Search size={15} />
      <!-- svelte-ignore a11y_autofocus -->
      <input autofocus placeholder="Songs, artists, moods" value={query} oninput={(e) => setQuery(e.currentTarget.value)} />
      {#if loading}<Spinner />{/if}
    </label>
  </header>

  <div class="scroll">
    <div class="moods">
      {#each moods as m (m.id)}
        <button class="mood" class:on={!query && mood?.id === m.id} style:--tint={m.tint} onclick={() => choose(m)}>
          <span class="disc"></span>
          <span class="name">{m.name}</span>
        </button>
      {/each}
    </div>

    <h2>{heading}</h2>

    {#if problem && !tracks.length}
      <p class="empty">{problem}</p>
    {:else if !tracks.length && !loading}
      <p class="empty">No tracks found. Try another word.</p>
    {/if}

    <ol>
      {#each tracks as t, i (t.id)}
        {@const current = previewing?.id === t.id}
        <li class:current title={t.about ?? ""}>
          <button class="row" onclick={() => togglePreview(t)}>
            <span class="num tabular">
              {#if current && playing}<span class="eq"><i></i><i></i><i></i></span>{:else}{i + 1}{/if}
            </span>
            <Artwork song={t} size={48} />
            <span class="text">
              <span class="title">{t.title}</span>
              <span class="sub">{detail(t)}</span>
            </span>
            <span class="licence">{licenseLabel(t)}</span>
            <span class="len tabular">{clock(t.duration)}</span>
          </button>
          <button class="pill-button" class:prominent={current} disabled={adding != null} onclick={() => use(t)}>
            {#if adding === t.id}<Spinner />{:else}Use{/if}
          </button>
        </li>
      {/each}
    </ol>
  </div>

  {#if previewing}
    <footer>
      <div class="bar" role="slider" aria-label="Position" aria-valuenow={progress} tabindex="-1" onclick={seekPreview} onkeydown={() => {}}>
        <span style:width="{progress * 100}%"></span>
      </div>
      <div class="now">
        <Artwork song={previewing} size={46} />
        <span class="text">
          <span class="title">{previewing.title}</span>
          <span class="sub">{previewing.artist}</span>
        </span>
        <span class="spacer"></span>
        <button class="play" onclick={() => previewing && togglePreview(previewing)} aria-label={playing ? "Pause" : "Play"}>
          {#if playing}<Pause size={15} fill="currentColor" />{:else}<Play size={15} fill="currentColor" />{/if}
        </button>
        <button class="pill-button prominent" disabled={adding != null} onclick={() => previewing && use(previewing)}>
          {#if adding === previewing.id}<Spinner /> Adding{:else}Use this track{/if}
        </button>
      </div>
    </footer>
  {/if}
</div>

<style>
  .scrim {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    z-index: 50;
  }
  .panel {
    position: fixed;
    z-index: 51;
    top: 44px;
    bottom: 44px;
    left: 50%;
    width: min(760px, calc(100vw - 32px));
    transform: translateX(-50%);
    display: flex;
    flex-direction: column;
    background: var(--panel);
    color: var(--moon-white);
    border-radius: 16px;
    box-shadow:
      0 0 0 1px rgba(255, 255, 255, 0.07),
      0 18px 80px rgba(0, 0, 0, 0.5);
    overflow: hidden;
    animation: rise var(--dur-base) var(--ease-base);
  }
  @keyframes rise {
    from {
      opacity: 0;
      transform: translateX(-50%) translateY(12px);
    }
  }
  header {
    padding: 22px 24px 14px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .titles {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  h1 {
    margin: 0;
    font-size: 26px;
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
    height: 38px;
    padding: 0 14px;
    border-radius: 19px;
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
    font-size: 14px;
  }
  .scroll {
    flex: 1;
    overflow-y: auto;
    padding: 0 24px 24px;
    scrollbar-width: none;
  }
  .scroll::-webkit-scrollbar {
    display: none;
  }
  .moods {
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    gap: 10px;
  }
  .mood {
    position: relative;
    height: 64px;
    border-radius: 10px;
    overflow: hidden;
    text-align: left;
    background: linear-gradient(135deg, var(--tint), color-mix(in srgb, var(--tint) 55%, transparent));
    box-shadow: inset 0 0 0 2px transparent;
    transition: box-shadow var(--dur-snappy) var(--ease-snappy);
  }
  .mood.on {
    box-shadow: inset 0 0 0 2px var(--violet);
  }
  .disc {
    position: absolute;
    width: 46px;
    height: 46px;
    right: -10px;
    top: -6px;
    border-radius: 50%;
    background: radial-gradient(circle, rgba(255, 255, 255, 0.12) 6px, rgba(0, 0, 0, 0.18) 6.5px);
    transform: rotate(22deg);
  }
  .mood .name {
    position: absolute;
    left: 10px;
    bottom: 10px;
    font-size: 14px;
    font-weight: 700;
  }
  h2 {
    margin: 22px 0 12px;
    font-size: 17px;
    font-weight: 700;
  }
  .empty {
    margin: 30px 0;
    font-size: 13px;
    color: var(--dim);
  }
  ol {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  li {
    display: flex;
    align-items: center;
    gap: 14px;
    height: 64px;
    padding: 0 10px;
    border-radius: 10px;
    transition: background var(--dur-snappy) var(--ease-snappy);
  }
  li.current {
    background: var(--midnight);
  }
  .row {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 14px;
    text-align: left;
    height: 100%;
  }
  .num {
    width: 26px;
    text-align: center;
    font-size: 12.5px;
    font-weight: 500;
    color: var(--faint);
  }
  .current .num,
  .current .title {
    color: var(--violet);
  }
  .text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .title {
    font-size: 14px;
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .sub {
    font-size: 12px;
    color: var(--dim);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .licence {
    font-size: 10px;
    font-weight: 600;
    color: var(--dim);
    padding: 0 7px;
    height: 18px;
    line-height: 16px;
    border-radius: 9px;
    border: 1px solid var(--line);
    white-space: nowrap;
  }
  .len {
    width: 40px;
    text-align: right;
    font-size: 12.5px;
    color: var(--dim);
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
    background: var(--charcoal);
    animation: up var(--dur-base) var(--ease-base);
  }
  @keyframes up {
    from {
      transform: translateY(100%);
      opacity: 0;
    }
  }
  .bar {
    height: 3px;
    background: var(--line);
    cursor: pointer;
  }
  .bar span {
    display: block;
    height: 100%;
    background: var(--violet);
  }
  .now {
    display: flex;
    align-items: center;
    gap: 14px;
    height: 70px;
    padding: 0 20px;
  }
  .play {
    width: 38px;
    height: 38px;
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
