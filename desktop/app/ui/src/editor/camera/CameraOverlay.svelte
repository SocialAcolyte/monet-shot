<script lang="ts">
  // The live camera over the preview while recording yourself (CameraOverlay):
  // in its bubble, exactly where the render will put it, or filling the frame
  // for a clip of just you. Counts in with big soft numerals.
  import { onMount } from "svelte";
  import type { EditorStore } from "../store.svelte";
  import { watchCamera } from "../../lib/camera";

  /** w, h: the shown preview in px; k: shown px per canvas px. */
  let { store, w, h, k }: { store: EditorStore; w: number; h: number; k: number } = $props();

  let src = $state<string | null>(null);
  onMount(() => {
    const stop = watchCamera((u) => (src = u));
    return () => void stop.then((f) => f());
  });

  const look = $derived(store.edit.cameraLook);
  const b = $derived(store.editor.bubbleRect());
  const bh = $derived(b.h * k);
  const radius = $derived(look.shape === "circle" ? bh / 2 : bh * 0.2);
  const n = $derived(store.cameraPhase.kind === "countdown" ? store.cameraPhase.n : null);
</script>

<div class="overlay" style:width="{w}px" style:height="{h}px">
  {#if store.cameraAlone}
    <div class="full" class:mirror={look.mirror}>{#if src}<img {src} alt="" />{/if}</div>
  {:else}
    <div
      class="bubble"
      class:mirror={look.mirror}
      style:left="{b.x * k}px"
      style:top="{b.y * k}px"
      style:width="{b.w * k}px"
      style:height="{bh}px"
      style:border-radius="{radius}px"
      style:--rim="{Math.max(1.5, bh * 0.018)}px"
      style:box-shadow="0 {bh * 0.03}px {bh * 0.12}px rgba(0, 0, 0, 0.35)"
    >
      {#if src}<img {src} alt="" />{/if}
    </div>
  {/if}
  {#if n != null}
    {#key n}<span class="count">{n}</span>{/key}
  {/if}
</div>

<style>
  .overlay {
    position: absolute;
    inset: 0;
    margin: auto;
    pointer-events: none;
    overflow: hidden;
  }
  .full,
  .bubble {
    position: absolute;
    overflow: hidden;
    background: #1f1f1f;
  }
  .full {
    inset: 0;
  }
  .bubble::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: inherit;
    box-shadow: inset 0 0 0 var(--rim) rgba(255, 255, 255, 0.96);
  }
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
  .mirror img {
    transform: scaleX(-1);
  }
  .count {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
    font-size: 120px;
    font-weight: 600;
    color: #fff;
    text-shadow: 0 0 36px rgba(0, 0, 0, 0.45);
    animation: tick var(--dur-snappy) var(--ease-snappy);
  }
  @keyframes tick {
    from {
      opacity: 0;
      transform: translateY(-14px) scale(0.92);
    }
  }
</style>
