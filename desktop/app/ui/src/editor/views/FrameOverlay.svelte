<script lang="ts">
  import { capture } from "../../lib/pointer";
  // Over the preview while framing (FrameOverlay): the take shown whole, the
  // crop as a bright window in a dimmed frame, a box over each hidden part.
  // Hide tool: drag anywhere to draw a box; drag a box to move it, its
  // handles to resize it. Crop tool: drag the crop's edges.
  import type { EditorStore } from "../store.svelte";
  import type { NormRect } from "../core";
  import type { Rect } from "../plan";

  let { store, w, h }: { store: EditorStore; w: number; h: number } = $props();

  const f = $derived(store.takeRect(w));
  const take = $derived(store.framingTake);
  const crop = $derived(store.crop(take));
  const blurs = $derived(store.edit.blurs.filter((b) => b.take === take));
  const cropping = $derived(store.frameTool === "crop");
  const handles: [number, number][] = [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]];
  const label = (s: string) => (s === "pixelate" ? "Pixelate" : s === "solid" ? "Cover" : "Blur");

  const view = (r: NormRect): Rect => ({ x: f.x + r.x * f.w, y: f.y + r.y * f.h, w: r.w * f.w, h: r.h * f.h });

  /** The parts of the frame outside the crop: above, below, left, right. */
  const bands = $derived.by(() => {
    const c = view(crop);
    return [
      { x: f.x, y: f.y, w: f.w, h: c.y - f.y },
      { x: f.x, y: c.y + c.h, w: f.w, h: f.y + f.h - (c.y + c.h) },
      { x: f.x, y: c.y, w: c.x - f.x, h: c.h },
      { x: c.x + c.w, y: c.y, w: f.x + f.w - (c.x + c.w), h: c.h },
    ].filter((b) => b.w > 0.5 && b.h > 0.5);
  });

  let root: HTMLDivElement;
  const local = (e: PointerEvent) => {
    const r = root.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };

  /** Pointer drag helper: `move(dx, dy)` in view px from where it began. */
  function track(e: PointerEvent, min: number, start: () => void, move: (dx: number, dy: number) => void, end: () => void, tap?: () => void) {
    if (e.button !== 0) return;
    e.stopPropagation();
    const el = e.currentTarget as HTMLElement;
    capture(el, e.pointerId);
    const x0 = e.clientX, y0 = e.clientY;
    let started = false;
    const mv = (m: PointerEvent) => {
      const dx = m.clientX - x0, dy = m.clientY - y0;
      if (!started && Math.hypot(dx, dy) < min) return;
      if (!started) {
        started = true;
        start();
      }
      move(dx, dy);
    };
    const up = () => {
      el.removeEventListener("pointermove", mv);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", up);
      if (started) end();
      else tap?.();
    };
    el.addEventListener("pointermove", mv);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
  }

  // Empty space: draw a new box (hide tool), or let go of the selection.
  function draw(e: PointerEvent) {
    if (cropping) {
      store.selectBlur(null);
      return;
    }
    const a = local(e);
    track(
      e,
      4,
      () => {},
      (dx, dy) => {
        const b = { x: a.x + dx, y: a.y + dy };
        store.drawingBox = { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(dx), h: Math.abs(dy) };
      },
      () => {
        const box = store.drawingBox;
        store.drawingBox = null;
        if (!box) return;
        const n = (x: number, y: number) => [Math.min(Math.max((x - f.x) / f.w, 0), 1), Math.min(Math.max((y - f.y) / f.h, 0), 1)];
        const [ax, ay] = n(a.x, a.y);
        const [bx, by] = n(a.x === box.x ? box.x + box.w : box.x, a.y === box.y ? box.y + box.h : box.y);
        const r = store.c.normRectSpanning(ax, ay, bx, by);
        if (r.w * f.w > 6 && r.h * f.h > 6) store.addBlur(r);
      },
      () => store.selectBlur(null),
    );
  }

  function moveBox(e: PointerEvent, rect: NormRect, onSelect: () => void, onChange: (r: NormRect) => void) {
    track(
      e,
      2,
      () => {
        store.boxOrigin = rect;
        onSelect();
      },
      (dx, dy) => store.boxOrigin && onChange(store.c.normRectMoved(store.boxOrigin, dx / f.w, dy / f.h)),
      () => (store.boxOrigin = null),
      onSelect,
    );
  }

  function resizeBox(e: PointerEvent, rect: NormRect, hx: number, hy: number, minSize: number, onChange: (r: NormRect) => void) {
    track(
      e,
      1,
      () => (store.boxOrigin = rect),
      (dx, dy) => store.boxOrigin && onChange(store.c.normRectResized(store.boxOrigin, hx, hy, dx / f.w, dy / f.h, minSize)),
      () => (store.boxOrigin = null),
    );
  }
</script>

<div class="frame-overlay" bind:this={root} style:width="{w}px" style:height="{h}px" onpointerdown={draw} role="presentation">
  {#each bands as b, i (i)}
    <div class="band" class:cropping style:left="{b.x}px" style:top="{b.y}px" style:width="{b.w}px" style:height="{b.h}px"></div>
  {/each}

  {#each blurs as b (b.id)}
    {@const r = view(b.rect)}
    {@const selected = b.id === store.selectedBlurID}
    {@const timed = b.start != null || b.end != null}
    <div class="boxwrap" class:dimmed={cropping}>
      <div
        class="box blur"
        class:selected
        style:left="{r.x}px"
        style:top="{r.y}px"
        style:width="{r.w}px"
        style:height="{r.h}px"
        onpointerdown={(e) => moveBox(e, b.rect, () => store.selectBlur(b.id), (n) => store.setBlur(b.id, (x) => (x.rect = n)))}
        role="button"
        tabindex="-1"
      ></div>
      <span class="tag" class:selected style:left="{r.x}px" style:top="{Math.max(f.y, r.y - 21)}px">{label(b.style)}{timed ? " · timed" : ""}</span>
      {#if selected}
        {#each handles as [hx, hy], i (i)}
          <span
            class="handle"
            class:corner={hx !== 0.5 && hy !== 0.5}
            style:left="{r.x + hx * r.w}px"
            style:top="{r.y + hy * r.h}px"
            onpointerdown={(e) => resizeBox(e, b.rect, hx, hy, 0.02, (n) => store.setBlur(b.id, (x) => (x.rect = n)))}
            role="separator"
          ></span>
        {/each}
      {/if}
    </div>
  {/each}

  {#if cropping}
    {@const r = view(crop)}
    <div
      class="box crop"
      style:left="{r.x}px"
      style:top="{r.y}px"
      style:width="{r.w}px"
      style:height="{r.h}px"
      onpointerdown={(e) => moveBox(e, crop, () => {}, (n) => store.setCrop(n))}
      role="button"
      tabindex="-1"
    >
      <!-- Rule-of-thirds lines, faint. -->
      <span class="third v" style:left="33.333%"></span>
      <span class="third v" style:left="66.667%"></span>
      <span class="third h" style:top="33.333%"></span>
      <span class="third h" style:top="66.667%"></span>
    </div>
    {#each handles as [hx, hy], i (i)}
      <span
        class="handle"
        class:corner={hx !== 0.5 && hy !== 0.5}
        style:left="{r.x + hx * r.w}px"
        style:top="{r.y + hy * r.h}px"
        onpointerdown={(e) => resizeBox(e, crop, hx, hy, 0.1, (n) => store.setCrop(n))}
        role="separator"
      ></span>
    {/each}
  {/if}

  {#if store.drawingBox}
    {@const d = store.drawingBox}
    <div class="drawing" style:left="{d.x}px" style:top="{d.y}px" style:width="{d.w}px" style:height="{d.h}px"></div>
  {/if}
</div>

<style>
  .frame-overlay {
    position: absolute;
    left: 0;
    top: 0;
    overflow: hidden;
  }
  .band {
    position: absolute;
    background: rgba(0, 0, 0, 0.5);
    pointer-events: none;
  }
  .band.cropping {
    background: rgba(0, 0, 0, 0.62);
  }
  .boxwrap.dimmed {
    opacity: 0.45;
    pointer-events: none;
  }
  .box {
    position: absolute;
  }
  .box.blur {
    background: rgba(255, 255, 255, 0.04);
    outline: 1px dashed rgba(255, 255, 255, 0.85);
    outline-offset: -1px;
  }
  .box.blur.selected {
    background: rgba(255, 255, 255, 0.001);
    outline: 1.5px solid var(--violet);
    outline-offset: -1.5px;
  }
  .box.crop {
    outline: 1.5px solid #fff;
    outline-offset: -1.5px;
  }
  .third {
    position: absolute;
    background: rgba(255, 255, 255, 0.22);
    pointer-events: none;
  }
  .third.v {
    top: 0;
    bottom: 0;
    width: 0.5px;
  }
  .third.h {
    left: 0;
    right: 0;
    height: 0.5px;
  }
  .tag {
    position: absolute;
    height: 17px;
    padding: 0 6px;
    border-radius: 4px;
    background: rgba(23, 25, 27, 0.8);
    color: var(--moon-white);
    font-size: 10.5px;
    font-weight: 600;
    line-height: 17px;
    white-space: nowrap;
    pointer-events: none;
  }
  .tag.selected {
    background: var(--violet);
    color: var(--charcoal);
  }
  /* A bigger target than it looks. */
  .handle {
    position: absolute;
    width: 21px;
    height: 21px;
    margin: -10.5px 0 0 -10.5px;
    display: grid;
    place-items: center;
    touch-action: none;
  }
  .handle::before {
    content: "";
    width: 9px;
    height: 9px;
    border-radius: 2.5px;
    background: #fff;
    box-shadow:
      inset 0 0 0 1px rgba(23, 25, 27, 0.5),
      0 1px 2px rgba(0, 0, 0, 0.35);
  }
  .handle.corner::before {
    width: 11px;
    height: 11px;
  }
  .drawing {
    position: absolute;
    background: rgba(166, 187, 195, 0.18);
    outline: 1.5px solid var(--violet);
    outline-offset: -1.5px;
    pointer-events: none;
  }
</style>
