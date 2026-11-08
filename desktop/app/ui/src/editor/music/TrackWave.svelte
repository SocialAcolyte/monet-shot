<script lang="ts">
  // A track's waveform (TrackWave): thin bars, the stretch that plays under
  // the video brighter, and while it plays, a line where it is.
  let { peaks, part, at, lit }: { peaks: number[]; part: [number, number] | null; at: number | null; lit: boolean } = $props();
  const bars = $derived(peaks.length ? peaks : Array(64).fill(0.25));
</script>

<svg class="wave" viewBox="0 0 {bars.length} 20" preserveAspectRatio="none" aria-hidden="true">
  {#each bars as p, i (i)}
    {@const f = (i + 0.5) / bars.length}
    {@const inside = part != null && f >= part[0] && f <= part[1]}
    {@const h = Math.max(2, p * 20)}
    <rect x={i + 0.18} y={(20 - h) / 2} width="0.64" height={h} rx="0.32" class:inside class:lit={inside && lit} />
  {/each}
  {#if at != null}
    <rect class="head" x={at * bars.length - 0.12} y="0" width="0.24" height="20" />
  {/if}
</svg>

<style>
  .wave {
    display: block;
    width: calc(100% - 54px);
    height: 20px;
  }
  rect {
    fill: color-mix(in srgb, var(--moon-white) 16%, transparent);
  }
  rect.inside {
    fill: color-mix(in srgb, var(--moon-white) 62%, transparent);
  }
  rect.lit {
    fill: var(--violet);
  }
  rect.head {
    fill: var(--moon-white);
  }
</style>
