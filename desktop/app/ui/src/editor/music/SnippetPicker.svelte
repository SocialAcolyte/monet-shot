<script lang="ts">
  // The song as a waveform with a bright window the length of the video:
  // slide the window to choose which part of the song plays. It snaps to the
  // song's bar lines, and clicks into place where one of the song's lifts
  // (dots above) lands on a zoom (ticks in the window); both light up.
  // Alt drags freely.
  import type { EditorStore } from "../store.svelte";
  import type { MusicChoice } from "../core";
  import { clock } from "./music";

  let { store, music }: { store: EditorStore; music: MusicChoice } = $props();

  let width = $state(0);
  let canvas: HTMLCanvasElement | undefined = $state();
  const H = 52;
  const TOP = 8;

  const song = $derived(Math.max(music.track.duration, 0.1));
  const video = $derived(store.duration);
  const winW = $derived(Math.max(12, Math.min(width, (video / song) * width)));
  const winX = $derived((music.offset / song) * width);
  const landing = $derived(store.musicLanding);

  const css = (name: string) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  $effect(() => {
    const c = canvas;
    if (!c || width <= 0) return;
    const dpr = window.devicePixelRatio || 1;
    c.width = Math.round(width * dpr);
    c.height = H * dpr;
    const g = c.getContext("2d")!;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, width, H);
    const [moon, faint, dim, violet, clay] = ["--moon-white", "--faint", "--dim", "--violet", "--clay"].map(css);
    const h0 = H - TOP;
    const bars = store.musicWave.length ? store.musicWave : Array(120).fill(0.3);
    const step = width / bars.length;
    bars.forEach((v, i) => {
      const h = Math.max(2, v * h0 * 0.9);
      const x = i * step;
      const inside = x >= winX && x <= winX + winW;
      g.fillStyle = inside ? moon : faint;
      g.globalAlpha = inside ? 1 : 0.6;
      g.beginPath();
      g.roundRect(x, TOP + (h0 - h) / 2, Math.max(1, step - 1), h, 1);
      g.fill();
    });
    g.globalAlpha = 1;
    // The song's lifts, as dots above it.
    for (const lift of store.musicGrid?.lifts ?? []) {
      const x = (lift / song) * width;
      g.fillStyle = landing && Math.abs(landing.lift - lift) < 0.01 ? clay : dim;
      g.beginPath();
      g.arc(x, 2.5, 2.5, 0, Math.PI * 2);
      g.fill();
    }
    // The video's zooms, as ticks in the window.
    for (const z of store.zoomMoments) {
      if (z >= video) continue;
      const x = winX + (z / song) * width;
      const on = landing && Math.abs(landing.zoom - z) < 0.01;
      g.fillStyle = on ? clay : violet;
      g.globalAlpha = on ? 1 : 0.9;
      g.fillRect(x - 0.75, TOP, 1.5, h0);
    }
    g.globalAlpha = 1;
  });

  let dragFrom: number | null = null;
  function down(e: PointerEvent) {
    dragFrom = e.clientX;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }
  function moved(e: PointerEvent) {
    if (dragFrom == null || width <= 0) return;
    if (Math.abs(e.clientX - dragFrom) < 1) return;
    store.beginMusicDragIfNeeded();
    store.dragMusic(((e.clientX - dragFrom) / width) * song, e.altKey);
  }
  function up() {
    if (dragFrom == null) return;
    dragFrom = null;
    store.endMusicDrag();
  }
</script>

<div class="picker" bind:clientWidth={width} title="Drag to choose which part of the song plays. It snaps to the beat; hold Alt to place it freely">
  <canvas bind:this={canvas} style:width="{width}px" style:height="{H}px"></canvas>
  <div
    class="window"
    role="slider"
    tabindex="-1"
    aria-label="Which part of the song plays"
    aria-valuenow={music.offset}
    style:left="{winX}px"
    style:width="{winW}px"
    onpointerdown={down}
    onpointermove={moved}
    onpointerup={up}
    onpointercancel={up}
  ></div>
</div>
<p class="plays tabular" class:landing>
  Plays {clock(music.offset)}–{clock(Math.min(music.track.duration, music.offset + video))} of {clock(music.track.duration)}{landing ? " · lift on the zoom" : ""}
</p>

<style>
  .picker {
    position: relative;
    height: 52px;
  }
  canvas {
    display: block;
  }
  .window {
    position: absolute;
    top: 8px;
    bottom: 0;
    border-radius: 6px;
    border: 2px solid var(--violet);
    background: color-mix(in srgb, var(--violet) 12%, transparent);
    cursor: grab;
    touch-action: none;
  }
  .window:active {
    cursor: grabbing;
  }
  .plays {
    margin: -4px 0 0;
    font-size: 11px;
    color: var(--dim);
  }
  .plays.landing {
    color: var(--clay);
  }
</style>
