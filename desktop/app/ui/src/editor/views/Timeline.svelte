<script lang="ts">
  import { capture } from "../../lib/pointer";
  // The timeline on the finished video's clock (MonetShotTimeline): a ruler
  // to scrub, the clips end to end (each a filmstrip of its own take, with
  // handles to shorten or lengthen it; drag one to reorder), the zoom track,
  // where zooms ride on the footage they were made on, and the camera lane.
  import { ScanEye, MousePointer2, CircleUserRound, RectangleHorizontal } from "@lucide/svelte";
  import type { EditorStore } from "../store.svelte";
  import { stamp } from "../format";
  import { call, inTauri } from "../../lib/ipc";
  import { fileUrl } from "../../lib/files";
  import type { ZoomSegment } from "../core";
  import { laneMenu } from "../camera/laneMenu";

  let { store }: { store: EditorStore } = $props();

  const inset = 20;
  const rulerH = 22;
  const stripY = 30;
  const stripH = 54;
  const trackY = 96;
  const trackH = 32;
  const cameraH = 22;

  let width = $state(600);
  const w = $derived(Math.max(1, width - inset * 2));
  const d = $derived(Math.max(store.duration, 0.01));
  const pps = $derived(w / d);
  const X = (t: number) => inset + t * pps;
  const seconds = (x: number) => (x - inset) / pps;

  // A tick every second (every 5 or 10 on long videos), labels on the majors.
  const ticks = $derived.by(() => {
    const step = d > 120 ? 10 : d > 40 ? 5 : 1;
    const major = step * (d > 40 ? 2 : 5);
    const out: { t: number; major: boolean }[] = [];
    for (let t = 0; t <= d + 1e-9; t += step) out.push({ t, major: t % major < 0.001 });
    return out;
  });

  // Filmstrips, one sheet per take.
  interface Strip { url: string; count: number; cols: number; tileW: number; tileH: number; step: number }
  let strips = $state<Record<number, Strip>>({});
  $effect(() => {
    store.takes.forEach((t, i) => {
      if (strips[i] || !inTauri) return;
      call<Strip & { path: string }>("filmstrip", { video: t.video, duration: t.meta.duration }).then(
        (s) => (strips[i] = { ...s, url: fileUrl(s.path) }),
        (e) => console.error(e),
      );
    });
  });

  /** CSS for one tile showing take `take` near `time`. */
  function tile(take: number, time: number, tw: number, th: number): string {
    const s = strips[take];
    if (!s) return "";
    const i = Math.min(s.count - 1, Math.max(0, Math.floor(time / s.step)));
    // Scale the sheet so one tile covers tw×th (aspect fill).
    const k = Math.max(tw / s.tileW, th / s.tileH);
    const ox = (tw - s.tileW * k) / 2, oy = (th - s.tileH * k) / 2;
    const col = i % s.cols, row = Math.floor(i / s.cols);
    const rows = Math.ceil(s.count / s.cols);
    return `background-image:url("${s.url}");background-size:${s.cols * s.tileW * k}px ${rows * s.tileH * k}px;background-position:${ox - col * s.tileW * k}px ${oy - row * s.tileH * k}px`;
  }

  /** A drag measured from where it began, in timeline seconds. */
  function dragger(opts: {
    min?: number;
    begin: () => void;
    change: (seconds: number, e: PointerEvent) => void;
    end: () => void;
    click?: (e: PointerEvent) => void;
  }) {
    return (e: PointerEvent) => {
      if (e.button !== 0) return;
      e.stopPropagation();
      const el = e.currentTarget as HTMLElement;
      capture(el, e.pointerId);
      const x0 = e.clientX;
      let started = false;
      const move = (m: PointerEvent) => {
        const dx = m.clientX - x0;
        if (!started && Math.abs(dx) < (opts.min ?? 2)) return;
        if (!started) {
          started = true;
          opts.begin();
        }
        opts.change(dx / pps, m);
      };
      const up = (u: PointerEvent) => {
        el.removeEventListener("pointermove", move);
        el.removeEventListener("pointerup", up);
        el.removeEventListener("pointercancel", up);
        if (started) opts.end();
        else opts.click?.(u);
      };
      el.addEventListener("pointermove", move);
      el.addEventListener("pointerup", up);
      el.addEventListener("pointercancel", up);
    };
  }

  // The ruler scrubs.
  function scrub(e: PointerEvent) {
    const el = e.currentTarget as HTMLElement;
    capture(el, e.pointerId);
    const at = (m: PointerEvent) => store.seek(seconds(m.clientX - el.getBoundingClientRect().left));
    at(e);
    const move = (m: PointerEvent) => at(m);
    const up = () => {
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
  }

  function localX(e: PointerEvent | MouseEvent) {
    return e.clientX - (e.currentTarget as HTMLElement).getBoundingClientRect().left;
  }

  const follows = (s: ZoomSegment) => s.focusX == null;
</script>

<div class="timeline" bind:clientWidth={width} style:height="{store.edit.cameraClips.length ? 186 - 20 : 158 - 20}px">
  <!-- Ruler -->
  <div class="ruler" style:height="{rulerH}px" onpointerdown={scrub} role="slider" aria-label="Playhead" aria-valuenow={store.time} tabindex="-1">
    {#each ticks as t (t.t)}
      <span class="tick" class:major={t.major} style:left="{X(t.t)}px"></span>
      {#if t.major}<span class="label tabular" style:left="{X(t.t) + 4}px">{stamp(t.t).replace(".0", "")}</span>{/if}
    {/each}
  </div>

  <div class="lane" style:left="{inset}px" style:top="{stripY}px" style:width="{w}px" style:height="{stripH}px"></div>

  {#each store.clips as clip, i (i)}
    {@const cw = Math.max(6, (clip.end - clip.start) * pps)}
    {@const lifted = store.moving?.index === i}
    {@const selected = store.selectedClip === i}
    {@const n = Math.max(1, Math.ceil(cw / (stripH * 1.6)))}
    <div
      class="clip"
      class:selected
      class:lifted
      style:left="{X(store.starts[i]) + (lifted ? (store.moving?.offset ?? 0) * pps : 0) + 1}px"
      style:top="{stripY}px"
      style:width="{cw - 2}px"
      style:height="{stripH}px"
      onpointerdown={dragger({
        min: 4,
        begin: () => store.beginMove(i),
        change: (s) => store.move(s),
        end: () => store.endMove(),
        click: (e) => {
          store.selectClip(i);
          store.seek(store.starts[i] + localX(e) / pps);
        },
      })}
      role="button"
      tabindex="-1"
    >
      <div class="film">
        {#each Array(n) as _, kk (kk)}
          {@const t = clip.start + ((kk + 0.5) / n) * (clip.end - clip.start)}
          <div class="tile" style={tile(clip.take, t, (cw - 2) / n, stripH)}></div>
        {/each}
      </div>
      {#if store.takes.length > 1 && cw > 54}<span class="badge">Take {clip.take + 1}</span>{/if}
      <div class="rim"></div>
      {#each [true, false] as leading (leading)}
        <div
          class="handle"
          class:leading
          style:opacity={cw > 22 ? 1 : 0.6}
          title={leading ? "Drag to change where this clip starts" : "Drag to change where this clip ends"}
          onpointerdown={dragger({
            min: 1,
            begin: () => store.beginClipDrag(i, leading),
            change: (s) => store.dragClip(s),
            end: () => store.endClipDrag(),
          })}
          role="separator"
        >
          <span class="grip"></span>
        </div>
      {/each}
    </div>
  {/each}

  <!-- The zoom track: empty space deselects, a double-click adds. -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div
    class="lane track"
    style:left="{inset}px"
    style:top="{trackY}px"
    style:width="{w}px"
    style:height="{trackH}px"
    onclick={() => store.select(null)}
    ondblclick={(e) => store.addZoom(seconds(localX(e) + inset))}
    role="presentation"
  >
    {#if store.edit.segments.length === 0}<span class="empty">Double-click to add a zoom, or press Z</span>{/if}
  </div>

  {#each store.zoomPlacements as z (z.id)}
    {@const zw = Math.max(8, (z.end - z.start) * pps)}
    {@const sel = store.selectedID === z.segment.id}
    <div
      class="zoom"
      class:sel
      style:left="{X(z.start)}px"
      style:top="{trackY}px"
      style:width="{zw}px"
      style:height="{trackH}px"
      onpointerdown={dragger({
        begin: () => store.beginDrag(z.segment.id),
        change: (s) => store.drag(z.segment.id, null, s),
        end: () => store.endDrag(),
        click: () => store.select(z.segment.id),
      })}
      role="button"
      tabindex="-1"
    >
      {#if zw > 54}
        <span class="zlabel">
          {#if follows(z.segment)}<MousePointer2 size={10} strokeWidth={2.6} />{:else}<ScanEye size={10} strokeWidth={2.6} />{/if}
          <span class="tabular">{z.segment.scale.toFixed(1)}×</span>
        </span>
      {/if}
      {#each ["leading", "trailing"] as const as edge (edge)}
        <div
          class="zhandle"
          class:leading={edge === "leading"}
          style:width="{Math.min(9, zw / 3)}px"
          onpointerdown={dragger({
            begin: () => store.beginDrag(z.segment.id),
            change: (s) => store.drag(z.segment.id, edge, s),
            end: () => store.endDrag(),
          })}
          role="separator"
        >
          {#if zw > 30}<span class="zgrip"></span>{/if}
        </div>
      {/each}
    </div>
  {/each}

  <!-- You on camera, recorded over the video. -->
  {#each store.edit.cameraClips as c (c.id)}
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    {@const cw = Math.max(8, (Math.min(c.at + c.duration, d) - c.at) * pps)}
    <div
      class="cam"
      style:left="{X(c.at)}px"
      style:top="{trackY + trackH + 6}px"
      style:width="{cw}px"
      style:height="{cameraH}px"
      onclick={() => store.seek(c.at + 0.05)}
      oncontextmenu={(e) => laneMenu(store, c.id, e)}
      title="You on camera: right-click for bubble or full frame"
      role="button"
      tabindex="-1"
    >
      {#if cw > 44}
        <span class="clabel">
          {#if c.full}<RectangleHorizontal size={11} />{:else}<CircleUserRound size={11} />{/if}
          {c.full ? "You, full frame" : "You"}
        </span>
      {/if}
    </div>
  {/each}

  <div class="playhead" style:left="{X(store.time) - 4.5}px">
    <span class="knob"></span>
    <span class="line"></span>
  </div>
</div>

<style>
  .timeline {
    position: relative;
    margin: 10px 0;
    background: var(--charcoal);
    overflow: hidden;
  }
  .ruler {
    position: absolute;
    left: 0;
    right: 0;
    top: 0;
  }
  .tick {
    position: absolute;
    bottom: 0;
    width: 1px;
    height: 4px;
    background: rgba(230, 227, 221, 0.16);
  }
  .tick.major {
    height: 8px;
    background: var(--faint);
  }
  .label {
    position: absolute;
    top: 1px;
    font-size: 9.5px;
    font-weight: 500;
    color: var(--faint);
    white-space: nowrap;
  }
  .lane {
    position: absolute;
    border-radius: 8px;
    background: var(--panel);
  }
  .empty {
    position: absolute;
    left: 12px;
    top: 50%;
    transform: translateY(-50%);
    font-size: 11px;
    color: var(--faint);
    white-space: nowrap;
  }
  .clip {
    position: absolute;
    border-radius: 8px;
    z-index: 1;
    transition:
      transform var(--dur-snappy) var(--ease-snappy),
      box-shadow var(--dur-snappy) var(--ease-snappy),
      opacity var(--dur-snappy) var(--ease-snappy);
  }
  .clip.lifted {
    z-index: 2;
    transform: scale(1.03);
    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);
    opacity: 0.92;
  }
  @media (prefers-reduced-motion: reduce) {
    .clip.lifted {
      transform: none;
    }
  }
  .film {
    position: absolute;
    inset: 0;
    display: flex;
    border-radius: 8px;
    overflow: hidden;
    background: var(--midnight);
  }
  .tile {
    flex: 1;
    height: 100%;
    background-repeat: no-repeat;
  }
  .badge {
    position: absolute;
    left: 14px;
    top: 5px;
    height: 15px;
    padding: 0 6px;
    border-radius: 8px;
    background: rgba(23, 25, 27, 0.78);
    font-size: 9.5px;
    font-weight: 700;
    line-height: 15px;
    pointer-events: none;
  }
  /* A light frame inside a dark hairline: legible on light and dark footage. */
  .rim {
    position: absolute;
    inset: 0;
    border-radius: 8px;
    box-shadow:
      inset 0 0 0 1px rgba(23, 25, 27, 0.9),
      inset 0 0 0 3px var(--moon-white);
    pointer-events: none;
    transition: box-shadow var(--dur-snappy) var(--ease-snappy);
  }
  .selected .rim {
    box-shadow:
      inset 0 0 0 1px rgba(23, 25, 27, 0.9),
      inset 0 0 0 3.5px var(--violet);
  }
  .handle {
    position: absolute;
    top: 0;
    bottom: 0;
    right: 0;
    width: 16px;
    display: flex;
    justify-content: flex-end;
    cursor: ew-resize;
  }
  .handle.leading {
    left: 0;
    right: auto;
    justify-content: flex-start;
  }
  .handle::before {
    content: "";
    width: 10px;
    height: 100%;
    background: var(--midnight);
    border-radius: 0 8px 8px 0;
    transition: background var(--dur-snappy) var(--ease-snappy);
  }
  .handle.leading::before {
    border-radius: 8px 0 0 8px;
  }
  .selected .handle::before {
    background: var(--violet);
  }
  .grip {
    position: absolute;
    top: 50%;
    right: 4px;
    width: 2px;
    height: 16px;
    margin-top: -8px;
    border-radius: 1px;
    background: rgba(230, 227, 221, 0.85);
  }
  .handle.leading .grip {
    left: 4px;
    right: auto;
  }
  .selected .grip {
    background: rgba(23, 25, 27, 0.7);
  }
  .zoom {
    position: absolute;
    z-index: 3;
    border-radius: 8px;
    background: var(--midnight);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
    display: grid;
    place-items: center;
    color: var(--dim);
    transition:
      background var(--dur-snappy) var(--ease-snappy),
      box-shadow var(--dur-snappy) var(--ease-snappy);
  }
  .zoom.sel {
    background: rgba(166, 187, 195, 0.28);
    box-shadow: inset 0 0 0 1.5px var(--violet);
    color: var(--moon-white);
  }
  .zlabel {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    font-weight: 600;
    pointer-events: none;
  }
  .zhandle {
    position: absolute;
    top: 0;
    bottom: 0;
    right: 0;
    display: grid;
    place-items: center;
    cursor: ew-resize;
  }
  .zhandle.leading {
    left: 0;
    right: auto;
  }
  .zgrip {
    width: 2px;
    height: 12px;
    border-radius: 1px;
    background: var(--faint);
  }
  .sel .zgrip {
    background: var(--violet);
  }
  .cam {
    position: absolute;
    z-index: 3;
    border-radius: 6px;
    background: rgba(166, 187, 195, 0.22);
    box-shadow: inset 0 0 0 1px rgba(166, 187, 195, 0.5);
    overflow: hidden;
  }
  .clabel {
    position: absolute;
    left: 7px;
    top: 50%;
    transform: translateY(-50%);
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 10.5px;
    font-weight: 600;
    color: rgba(230, 227, 221, 0.85);
    white-space: nowrap;
  }
  .playhead {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 9px;
    z-index: 4;
    pointer-events: none;
    display: flex;
    flex-direction: column;
    align-items: center;
  }
  .knob {
    width: 9px;
    height: 12px;
    border-radius: 2.5px;
    background: var(--violet);
    flex: none;
  }
  .line {
    width: 1.5px;
    flex: 1;
    margin-top: -1px;
    background: var(--violet);
  }
</style>
