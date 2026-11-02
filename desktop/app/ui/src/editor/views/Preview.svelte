<script lang="ts">
  // The live render, letterboxed in the charcoal (PreviewArea). Clicking it
  // while a zoom that holds still is selected moves where that zoom looks.
  // Drop a picture anywhere on it to make it the background.
  import { onMount, type Snippet } from "svelte";
  import { Painter } from "../painter";
  import { Playback } from "../playback";
  import type { EditorStore } from "../store.svelte";

  let { store, playback = $bindable(), overlay }: { store: EditorStore; playback?: Playback; overlay?: Snippet<[{ w: number; h: number; k: number }]> } = $props();

  let area: HTMLDivElement;
  let canvas: HTMLCanvasElement;
  let aw = $state(1), ah = $state(1);
  let failed = $state<string | null>(null);
  let notice = $state<string | null>(null);

  const c = $derived(store.canvas);
  const k = $derived(Math.min(aw / c.width, ah / c.height));
  const shown = $derived({ w: Math.max(1, Math.floor(c.width * k)), h: Math.max(1, Math.floor(c.height * k)) });

  // Anything the picture depends on marks it for repainting.
  $effect(() => {
    void store.time;
    void store.version;
    void shown.w;
    void shown.h;
    if (playback) playback.dirty = true;
  });

  onMount(() => {
    let painter: Painter;
    try {
      painter = new Painter(canvas);
    } catch (e) {
      failed = String(e);
      return;
    }
    const pb = new Playback(store);
    pb.onNotice = (t) => (notice = t);
    playback = pb;
    let frame = 0;
    const loop = () => {
      frame = requestAnimationFrame(loop);
      try {
        const plan = pb.tick();
        if (plan) {
          painter.resize(shown.w, shown.h);
          painter.paint(plan, pb);
        }
      } catch (e) {
        console.error("paint", e);
      }
    };
    frame = requestAnimationFrame(loop);
    const ro = new ResizeObserver(([e]) => {
      aw = e.contentRect.width;
      ah = e.contentRect.height;
    });
    ro.observe(area);
    return () => {
      cancelAnimationFrame(frame);
      ro.disconnect();
      pb.destroy();
    };
  });

  function click(e: MouseEvent) {
    const sel = store.selected;
    // A zoom that follows the cursor has no point to choose.
    if (!sel || sel.focusX == null || store.framing || store.cameraPhase.kind !== "off") return;
    const r = canvas.getBoundingClientRect();
    const q = store.contentPoint(e.clientX - r.left, e.clientY - r.top, r.width, r.height);
    if (q) store.setFocus(q);
  }

  function dragover(e: DragEvent) {
    if ([...(e.dataTransfer?.items ?? [])].some((i) => i.type.startsWith("image/"))) e.preventDefault();
  }
</script>

<div class="area" bind:this={area} ondragover={dragover} role="presentation">
  <div class="shown" style:width="{shown.w}px" style:height="{shown.h}px">
    <canvas bind:this={canvas} style:width="{shown.w}px" style:height="{shown.h}px" onclick={click}></canvas>
    {#if overlay}{@render overlay({ w: shown.w, h: shown.h, k })}{/if}
    {#if failed}<p class="failed">The preview can't draw here: {failed}</p>{/if}
    {#if notice}<p class="notice">{notice}</p>{/if}
  </div>
</div>

<style>
  .area {
    flex: 1;
    min-height: 0;
    display: grid;
    place-items: center;
    overflow: hidden;
  }
  .shown {
    position: relative;
    border-radius: 6px;
    overflow: hidden;
    background: #121212;
  }
  .shown::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: 6px;
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.06);
    pointer-events: none;
  }
  canvas {
    display: block;
  }
  .notice {
    position: absolute;
    left: 50%;
    bottom: 14px;
    transform: translateX(-50%);
    max-width: calc(100% - 40px);
    margin: 0;
    padding: 7px 12px;
    border-radius: 9px;
    background: rgba(23, 25, 27, 0.92);
    color: var(--moon-white);
    font-size: 12px;
    text-align: center;
    pointer-events: none;
  }
  .failed {
    position: absolute;
    inset: 0;
    margin: 0;
    display: grid;
    place-items: center;
    color: var(--dim);
    font-size: 12px;
    padding: 20px;
    text-align: center;
  }
</style>
