<script lang="ts">
  // Replaces the transport while the camera is out (CameraBar): put it away,
  // over the video or just me, which camera, what's happening, Record/Stop.
  import { X, Video } from "@lucide/svelte";
  import type { EditorStore } from "../store.svelte";
  import Segmented from "../parts/Segmented.svelte";
  import { stamp } from "../format";
  import { inTauri } from "../../lib/ipc";
  import { cameraUi } from "./state.svelte";
  import { useCamera } from "./flow";

  let { store }: { store: EditorStore } = $props();

  const phase = $derived(store.cameraPhase);
  const ready = $derived(phase.kind === "ready");
  const recording = $derived(phase.kind === "recording");

  let now = $state(Date.now());
  $effect(() => {
    if (!recording) return;
    const t = setInterval(() => (now = Date.now()), 250);
    return () => clearInterval(t);
  });

  const cameraName = $derived(cameraUi.cameras.find((c) => c.id === cameraUi.camera)?.name ?? cameraUi.cameras[0]?.name ?? "Camera");

  async function cameraMenu(e: MouseEvent) {
    if (!inTauri || !ready) return;
    const { Menu, CheckMenuItem } = await import("@tauri-apps/api/menu");
    const { LogicalPosition } = await import("@tauri-apps/api/dpi");
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const items = await Promise.all(
      cameraUi.cameras.map((c) =>
        CheckMenuItem.new({ text: c.name, checked: c.name === cameraName, action: () => useCamera(c.id) }),
      ),
    );
    const m = await Menu.new({ items });
    await m.popup(new LogicalPosition(r.left, r.bottom + 4));
  }
</script>

<div class="bar">
  <button class="pill-button icon" onclick={() => store.closeCamera()} title="Put the camera away (Esc)" aria-label="Put the camera away">
    <X strokeWidth={3} />
  </button>

  <span title="Talk over the video as it plays, or record a clip of just you (added at the end)">
    <Segmented
      fit
      disabled={!ready}
      options={[
        { value: false, label: "Over the video" },
        { value: true, label: "Just me" },
      ]}
      value={store.cameraAlone}
      onchange={(v) => (store.cameraAlone = v)}
    />
  </span>

  <button class="pill-button" disabled={!ready} onclick={cameraMenu} title="Which camera">
    <Video /> <span class="name">{cameraName}</span>
  </button>

  <span class="spacer"></span>

  <span class="status tabular">
    {#if phase.kind === "recording"}
      <span class="dot"></span>{stamp((now - phase.since) / 1000)}
    {:else if phase.kind === "countdown"}
      Get ready…
    {:else if phase.kind === "saving"}
      Saving…
    {:else}
      {store.cameraAlone ? "Space to record a clip of you" : "Space to talk over the video from the playhead"}
    {/if}
  </span>

  <button
    class="record"
    disabled={phase.kind === "saving"}
    onclick={() => store.toggleCameraRecording()}
    title={recording ? "Stop (Space)" : "Start after a 3-second count (Space)"}
  >
    {#if recording}<span class="square"></span>{:else}<span class="circle"></span>{/if}
    {recording ? "Stop" : "Record"}
  </button>
</div>

<style>
  .bar {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .spacer {
    flex: 1;
  }
  .icon {
    padding: 0 8px;
  }
  .name {
    max-width: 160px;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .status {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    font-weight: 500;
    color: var(--dim);
    white-space: nowrap;
  }
  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--clay);
  }
  .record {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    height: 28px;
    padding: 0 14px;
    border-radius: 14px;
    background: var(--clay);
    color: #fff;
    font-size: 12.5px;
    font-weight: 600;
    transition: transform var(--dur-snappy) var(--ease-snappy);
  }
  .record:active:not(:disabled) {
    transform: scale(0.97);
  }
  .record:disabled {
    opacity: 0.6;
  }
  .circle,
  .square {
    width: 10px;
    height: 10px;
    background: #fff;
  }
  .circle {
    border-radius: 50%;
  }
  .square {
    border-radius: 2.5px;
  }
</style>
