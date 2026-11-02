<script lang="ts">
  import { capture } from "../lib/pointer";
  // Press and hold to stop: a ring draws round the square for 0.6 s; letting
  // go early or dragging away springs it back, so a stray click can't end a
  // take (HoldRing + MenuBarModel.holdBegan/holdEnded).
  import { holdDuration } from "../lib/motion";
  let { onstop }: { onstop: () => void } = $props();

  let progress = $state(0);
  let holding = $state(false);
  let start = { x: 0, y: 0, t: 0 };
  let frame = 0;
  const C = 2 * Math.PI * 8.2;

  function step() {
    if (!holding) return;
    progress = Math.min(1, (performance.now() - start.t) / holdDuration);
    if (progress >= 1) {
      holding = false;
      onstop();
      return;
    }
    frame = requestAnimationFrame(step);
  }

  function down(e: PointerEvent) {
    if (e.button !== 0) return;
    capture(e.currentTarget as Element, e.pointerId);
    start = { x: e.clientX, y: e.clientY, t: performance.now() };
    holding = true;
    frame = requestAnimationFrame(step);
  }

  function move(e: PointerEvent) {
    if (holding && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 12) end();
  }

  function end() {
    if (!holding) return;
    holding = false;
    cancelAnimationFrame(frame);
    progress = 0;
  }
</script>

<button
  class="hold"
  class:holding
  title="Hold to stop recording"
  aria-label="Hold to stop recording"
  onpointerdown={down}
  onpointermove={move}
  onpointerup={end}
  onpointercancel={end}
  onlostpointercapture={end}
>
  <svg width="18" height="18" viewBox="0 0 18 18">
    <circle cx="9" cy="9" r="8.2" fill="none" stroke-width="1.6" class="track" />
    <circle
      cx="9"
      cy="9"
      r="8.2"
      fill="none"
      stroke-width="1.6"
      stroke-linecap="round"
      class="progress"
      class:spring={!holding}
      stroke-dasharray={C}
      stroke-dashoffset={C * (1 - progress)}
      opacity={progress > 0 ? 1 : 0}
      transform="rotate(-90 9 9)"
    />
    <rect x="6" y="6" width="6" height="6" rx="1.5" class="square" />
  </svg>
</button>

<style>
  .hold {
    width: 20px;
    height: 20px;
    display: grid;
    place-items: center;
    flex: none;
    touch-action: none;
  }
  svg {
    transition: transform var(--dur-snappy) var(--ease-snappy);
  }
  .holding svg {
    transform: scale(1.12);
  }
  @media (prefers-reduced-motion: reduce) {
    .holding svg {
      transform: none;
    }
  }
  .track {
    stroke: rgba(230, 227, 221, 0.18);
  }
  .progress {
    stroke: var(--violet);
  }
  .progress.spring {
    transition: stroke-dashoffset var(--dur-snappy) var(--ease-snappy);
  }
  .square {
    fill: rgba(230, 227, 221, 0.85);
  }
</style>
