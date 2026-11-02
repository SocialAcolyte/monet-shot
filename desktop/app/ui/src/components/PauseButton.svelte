<script lang="ts">
  // Pause / resume. The paused stretch is cut from the video, so every pause
  // ends a clip and every resume starts the next.
  let { paused, onclick }: { paused: boolean; onclick: () => void } = $props();
</script>

<button
  class="pause"
  class:paused
  {onclick}
  title={paused ? "Resume (double-tap Shift)" : "Pause; the pause is cut out (double-tap Shift)"}
  aria-label={paused ? "Resume" : "Pause"}
>
  <svg width="18" height="18" viewBox="0 0 18 18">
    <circle cx="9" cy="9" r="8.2" fill="none" stroke-width="1.6" class="track" />
    {#if paused}
      <path d="M7.1 5.6 L12.2 9 L7.1 12.4 Z" class="glyph" stroke-linejoin="round" stroke-width="1" />
    {:else}
      <rect x="6.1" y="5.6" width="2" height="6.8" rx="0.6" class="glyph" />
      <rect x="9.9" y="5.6" width="2" height="6.8" rx="0.6" class="glyph" />
    {/if}
  </svg>
</button>

<style>
  .pause {
    width: 20px;
    height: 20px;
    display: grid;
    place-items: center;
    flex: none;
  }
  .track {
    stroke: rgba(230, 227, 221, 0.18);
  }
  .glyph {
    fill: rgba(230, 227, 221, 0.85);
    stroke: rgba(230, 227, 221, 0.85);
    stroke-width: 0;
  }
  .paused .glyph {
    fill: var(--clay);
    stroke: var(--clay);
    stroke-width: 1;
  }
</style>
