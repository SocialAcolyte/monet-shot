<script lang="ts">
  // The record controls the Mac draws inside its menu bar (StatusRootView),
  // in a small always-on-top window: trays elsewhere can only show an icon.
  // Flat charcoal, no blur, the same pieces in the same order.
  import { onMount } from "svelte";
  import Aperture from "../components/Aperture.svelte";
  import Rolling from "../components/Rolling.svelte";
  import PauseButton from "../components/PauseButton.svelte";
  import HoldRing from "../components/HoldRing.svelte";
  import { call, on, elapsed, clock, inTauri, type BarState } from "../lib/ipc";
  import { reveal, fade } from "../lib/motion";

  let bar = $state<BarState | null>(null);
  let now = $state(Date.now());
  let surface: HTMLElement;

  const phase = $derived(bar?.phase.kind ?? "idle");
  const recording = $derived(phase === "recording" || phase === "saving");
  const busy = $derived(phase === "picking" || phase === "starting");

  onMount(() => {
    call<BarState>("bar_state").then((s) => (bar = s));
    const off = on<BarState>("bar", (s) => (bar = s));
    // GTK forgets a hidden window's size: the app asks again once it's shown.
    const offRefit = on("pill-refit", () => setTimeout(fit, 30));
    const timer = setInterval(() => (now = Date.now()), 250);
    // The window is as wide as what it shows.
    const ro = new ResizeObserver(() => fit());
    ro.observe(surface);
    return () => {
      off.then((f) => f());
      offRefit.then((f) => f());
      clearInterval(timer);
      ro.disconnect();
    };
  });

  async function fit() {
    if (!inTauri || !surface) return;
    const { getCurrentWindow, LogicalSize } = await import("@tauri-apps/api/window");
    const r = surface.getBoundingClientRect();
    await getCurrentWindow().setSize(new LogicalSize(Math.ceil(r.width) + 12, 34));
  }

  const tap = () => call("bar_tap");
</script>

<div class="stage" data-tauri-drag-region>
  <div class="surface" bind:this={surface} data-tauri-drag-region>
    <button class="mark" onclick={tap} aria-label="Record">
      <Aperture {recording} {busy} paused={bar?.paused ?? false} />
    </button>

    {#if bar?.phase.kind === "countdown"}
      <button class="count" onclick={() => call("bar_cancel")} transition:reveal title="Cancel">
        <Rolling text={String(bar.phase.n)} down />
      </button>
    {:else if bar?.phase.kind === "recording"}
      <span class="time" class:paused={bar.paused} transition:reveal>
        <Rolling text={clock(elapsed(bar, now))} />
      </span>
      <span transition:reveal><PauseButton paused={bar.paused} onclick={() => call("bar_toggle_pause")} /></span>
      <span transition:reveal><HoldRing onstop={() => call("bar_stop")} /></span>
    {:else if bar?.phase.kind === "saving"}
      <span class="note" transition:fade>Saving</span>
    {:else if bar?.problem}
      <span class="note" transition:fade>{bar.problem}</span>
    {/if}
  </div>
</div>

<style>
  .stage {
    height: 100vh;
    display: flex;
    align-items: center;
    padding: 0 6px;
  }
  .surface {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 30px;
    padding: 0 8px;
    border-radius: 9px;
    background: rgba(23, 25, 27, 0.92);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.07);
    white-space: nowrap;
  }
  .mark {
    width: 16px;
    height: 16px;
    flex: none;
  }
  .stage > .surface > :global(span) {
    display: inline-flex;
  }
  .count {
    min-width: 22px;
    height: 19px;
    padding: 0 8px;
    border-radius: 7px;
    background: var(--midnight);
    font-size: 12px;
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  .time {
    font-size: 12px;
    font-weight: 600;
    color: var(--moon-white);
    transition: color var(--dur-base) var(--ease-base);
  }
  .time.paused {
    color: var(--dim);
  }
  .note {
    font-size: 12px;
    color: var(--dim);
  }
</style>
