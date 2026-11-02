<script lang="ts">
  // You, in a circle in the screen's corner during the 3-2-1 (CameraBubble):
  // mirrored, a white 3 pt rim, fading in over 0.25 s.
  import { onMount } from "svelte";
  import { watchCamera } from "../lib/camera";

  let src = $state<string | null>(null);
  onMount(() => {
    const stop = watchCamera((u) => (src = u));
    return () => void stop.then((f) => f());
  });
</script>

<div class="bubble" class:on={src}>
  {#if src}<img {src} alt="" />{/if}
</div>

<style>
  .bubble {
    width: 100vw;
    height: 100vh;
    border-radius: 50%;
    overflow: hidden;
    position: relative;
    background: #111;
    opacity: 0;
    transition: opacity 250ms ease-out;
  }
  .bubble.on {
    opacity: 1;
  }
  .bubble::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: 50%;
    box-shadow: inset 0 0 0 3px rgba(255, 255, 255, 0.95);
  }
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    transform: scaleX(-1);
  }
</style>
