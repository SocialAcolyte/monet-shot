<script lang="ts">
  // Album art from the library, or a generated cover: a warm gradient keyed
  // to the track's feel, faint record grooves in the corner, and its initial.
  import { coverTint, playable, type Song } from "./music";
  let { song, size }: { song: Song; size: number } = $props();

  let art = $state<string | null>(null);
  let failed = $state(false);
  $effect(() => {
    failed = false;
    playable(song.artworkURL).then((u) => (art = u));
  });
  const tint = $derived(coverTint(song));
</script>

<div class="art" style:width="{size}px" style:height="{size}px" style:border-radius="{size * 0.14}px">
  {#if art && !failed}
    <img src={art} alt="" onerror={() => (failed = true)} />
  {:else}
    <div class="cover" style:background="linear-gradient(135deg, {tint}, {tint}73), var(--charcoal)">
      {#each [0, 1, 2, 3] as k (k)}
        <span
          class="groove"
          style:width="{size * (0.5 + k * 0.28)}px"
          style:height="{size * (0.5 + k * 0.28)}px"
          style:left="{size * 0.95}px"
          style:top="{size * 0.1}px"
          style:border-width="{Math.max(0.6, size / 70)}px"
        ></span>
      {/each}
      <span class="initial" style:font-size="{size * 0.44}px" style:padding="0 0 {size * 0.04}px {size * 0.12}px">
        {song.title.slice(0, 1).toUpperCase()}
      </span>
    </div>
  {/if}
</div>

<style>
  .art {
    overflow: hidden;
    flex: none;
    position: relative;
  }
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
  .cover {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: flex-end;
  }
  .groove {
    position: absolute;
    border: solid rgba(255, 255, 255, 0.1);
    border-radius: 50%;
    transform: translate(-50%, -50%);
  }
  .initial {
    font-weight: 800;
    line-height: 1;
    color: rgba(255, 255, 255, 0.9);
  }
</style>
