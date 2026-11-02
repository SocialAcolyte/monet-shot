<script lang="ts">
  // Monet Shot's mark: a lens ring with a pupil of a dot. At rest both are
  // the ink colour; recording, the dot fills the ring in clay (Aperture).
  let {
    size = 16,
    recording = false,
    busy = false,
    paused = false,
  }: { size?: number; recording?: boolean; busy?: boolean; paused?: boolean } = $props();

  // Fixed 1.5 pt ring and 5 / 3.2 pt pupil insets, whatever the size.
  const r = $derived(size / 2);
  const pupil = $derived(r - (recording && !paused ? 3.2 : 5));
</script>

<svg
  class="aperture"
  class:recording
  width={size}
  height={size}
  viewBox="0 0 {size} {size}"
  style:--ink-alpha={busy && !recording ? 0.5 : 0.9}
  aria-hidden="true"
>
  <circle class="ring" cx={r} cy={r} r={r - 0.75} stroke-width="1.5" fill="none" />
  <circle class="pupil" cx={r} cy={r} r={Math.max(0, pupil)} style:opacity={paused ? 0.55 : 1} />
</svg>

<style>
  .aperture {
    display: block;
    color: var(--moon-white);
    flex: none;
  }
  .ring {
    stroke: color-mix(in srgb, currentColor calc(var(--ink-alpha) * 100%), transparent);
    transition: stroke var(--dur-base) var(--ease-base);
  }
  .pupil {
    fill: color-mix(in srgb, currentColor calc(var(--ink-alpha) * 100%), transparent);
    transition:
      r var(--dur-base) var(--ease-base),
      fill var(--dur-base) var(--ease-base),
      opacity var(--dur-base) var(--ease-base);
  }
  .recording .ring {
    stroke: var(--clay);
  }
  .recording .pupil {
    fill: var(--clay);
  }
</style>
