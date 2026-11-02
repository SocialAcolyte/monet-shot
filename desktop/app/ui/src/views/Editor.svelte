<script lang="ts">
  // The editor (EditorView + EditorWindow): preview over the transport on the
  // left, inspector on the right, timeline along the bottom. Flat charcoal;
  // colour only in the recording and the blue-grey of what's selected.
  import { onMount } from "svelte";
  import { EditorStore } from "../editor/store.svelte";
  import type { Playback } from "../editor/playback";
  import Preview from "../editor/views/Preview.svelte";
  import Transport from "../editor/views/Transport.svelte";
  import Timeline from "../editor/views/Timeline.svelte";
  import Inspector from "../editor/views/Inspector.svelte";
  import FrameOverlay from "../editor/views/FrameOverlay.svelte";
  import FrameBar from "../editor/views/FrameBar.svelte";
  import CameraOverlay from "../editor/camera/CameraOverlay.svelte";
  import CameraBar from "../editor/camera/CameraBar.svelte";
  import MusicBrowser from "../editor/music/MusicBrowser.svelte";
  import { call, on, inTauri } from "../lib/ipc";
  import { titleBarInset } from "../lib/platform";
  import { fade } from "../lib/motion";
  import type { Clip, Edit } from "../editor/core";

  let { reel }: { reel: string } = $props();

  let store = $state<EditorStore | null>(null);
  let failed = $state<string | null>(null);
  let playback = $state<Playback>();
  let exporting = false;

  onMount(() => {
    EditorStore.open(reel).then(
      (s) => {
        store = s;
        // Dev builds: the store on window, for poking at from the inspector.
        if (import.meta.env.DEV) (window as unknown as { monetshot: EditorStore }).monetshot = s;
        // Developer aids (see windows.rs): open at a time, with a selection or framing.
        const q = new URLSearchParams(location.search);
        if (q.get("t")) s.seek(+q.get("t")!);
        const sel = q.get("select");
        if (sel && s.edit.segments[+sel]) s.select(s.edit.segments[+sel].id);
        if (q.get("clip")) s.selectClip(+q.get("clip")!);
        if (q.get("music")) s.openMusic();
        if (q.get("export")) startExport();
        if (q.get("scroll") === "bottom") requestAnimationFrame(() => document.querySelector(".inspector .scroll")?.scrollTo(0, 1e6));
        const fr = q.get("framing");
        if (fr) {
          s.openFraming(fr === "crop" ? "crop" : "blur");
          const last = s.edit.blurs.at(-1);
          if (fr === "blur" && last) s.selectBlur(last.id);
        }
        if (inTauri) import("@tauri-apps/api/window").then(({ getCurrentWindow }) => getCurrentWindow().setTitle(s.title));
      },
      (e) => (failed = String(e)),
    );
    const offTake = on<{ project: string; clips: Clip[] }>("take-finished", (p) => {
      if (store && same(p.project, store.folder)) store.takeRecorded(p.clips);
    });
    const offDrop = listenForDrops();
    const save = () => store?.close();
    addEventListener("beforeunload", save);
    addEventListener("keydown", key);
    return () => {
      offTake.then((f) => f());
      offDrop.then((f) => f());
      removeEventListener("beforeunload", save);
      removeEventListener("keydown", key);
      store?.close();
    };
  });

  const same = (a: string, b: string) => a.replace(/[\\/]+$/, "") === b.replace(/[\\/]+$/, "");

  /** Editor shortcuts (EditorWindow.handleKey). Typing in a field keeps its keys. */
  function key(e: KeyboardEvent) {
    const s = store;
    if (!s) return;
    const t = e.target as HTMLElement;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) {
      if (t instanceof HTMLInputElement && t.type === "range") {
        // sliders: let the editor have its keys
      } else return;
    }
    const cmd = e.metaKey || e.ctrlKey;
    if (cmd && !e.altKey && e.key.toLowerCase() === "z") {
      e.preventDefault();
      e.shiftKey ? s.redo() : s.undo();
      return;
    }
    if (cmd && !e.altKey && e.key.toLowerCase() === "y") {
      e.preventDefault();
      s.redo();
      return;
    }
    if (cmd && e.key.toLowerCase() === "e") {
      e.preventDefault();
      startExport();
      return;
    }
    if (cmd || e.altKey) return;
    const k = e.key;
    // Recording yourself: space starts and stops, esc puts the camera away.
    if (s.cameraPhase.kind !== "off") {
      e.preventDefault();
      if (k === " ") s.toggleCameraRecording();
      else if (k === "Escape") s.closeCamera();
      return;
    }
    if (s.showingMusic) {
      if (k === "Escape") s.closeMusic();
      return;
    }
    // Framing: esc lets go of the box, then leaves; editing keys stay.
    if (s.framing && ![" ", "ArrowLeft", "ArrowRight", "Backspace", "Delete"].includes(k)) {
      e.preventDefault();
      if (k === "Escape") s.selectedBlurID ? s.selectBlur(null) : s.closeFraming();
      else if (k.toLowerCase() === "b") s.closeFraming();
      else if (k.toLowerCase() === "r") s.frameTool = s.frameTool === "crop" ? "blur" : "crop";
      return;
    }
    const handled = (() => {
      switch (k) {
        case " ":
          s.togglePlay();
          return true;
        case "ArrowLeft":
          s.step(e.shiftKey ? -60 : -1);
          return true;
        case "ArrowRight":
          s.step(e.shiftKey ? 60 : 1);
          return true;
        case "Backspace":
        case "Delete":
          s.deleteSelected();
          return true;
        case "Escape":
          s.select(null);
          s.selectClip(null);
          return true;
      }
      switch (k.toLowerCase()) {
        case "z":
          s.addZoom();
          return true;
        case "s":
          s.split();
          return true;
        case "m":
          s.openMusic();
          return true;
        case "a":
          s.reAuto();
          return true;
        case "c":
          s.openCamera();
          return true;
        case "b":
          s.openFraming();
          return true;
      }
      return false;
    })();
    if (handled) e.preventDefault();
  }

  /** Files dropped on the window: videos on the timeline become clips,
   *  a picture on the preview becomes the background. */
  async function listenForDrops(): Promise<() => void> {
    if (!inTauri) return () => {};
    const { getCurrentWebview } = await import("@tauri-apps/api/webview");
    return getCurrentWebview().onDragDropEvent((ev) => {
      if (ev.payload.type !== "drop" || !store) return;
      const { paths, position } = ev.payload;
      const x = position.x / devicePixelRatio, y = position.y / devicePixelRatio;
      const el = document.elementFromPoint(x, y);
      const isImage = (p: string) => /\.(jpe?g|png|webp|heic|gif|bmp|tiff?)$/i.test(p);
      const isVideo = (p: string) => /\.(mp4|mov|m4v|mkv|webm|avi|reel)$/i.test(p) || p.endsWith(".reel/");
      if (el?.closest(".preview-zone")) {
        const pic = paths.find(isImage);
        if (pic) store.setBackdropImage(pic);
      } else if (el?.closest(".timeline-zone")) {
        const vids = paths.filter(isVideo);
        if (vids.length) addFootage(vids);
      }
    });
  }

  async function addFootage(paths?: string[]) {
    const s = store;
    if (!s || !inTauri) return;
    if (!paths) {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const picked = await open({
        title: "Add a video or a Monet Shot recording to the end of this one",
        multiple: true,
        filters: [{ name: "Video", extensions: ["mp4", "mov", "m4v", "mkv", "webm", "avi"] }],
      });
      if (!picked) return;
      paths = Array.isArray(picked) ? picked : [picked];
    }
    try {
      const r = await call<{ edit: Edit | null; videoTakes: number[] }>("add_footage", { folder: s.folder, paths, edit: s.edit });
      await s.footageAdded(r.edit, r.videoTakes);
      playback?.syncTakes();
    } catch (e) {
      console.error("add footage", e);
    }
  }

  async function startExport() {
    const s = store;
    if (!s || exporting || s.exportProgress != null) return;
    if (s.playing) s.togglePlay();
    exporting = true;
    await s.save();
    s.exportProgress = 0;
    s.exportError = null;
    s.exportedPath = null;
    const off = await on<{ folder: string; progress: number }>("export-progress", (p) => {
      if (same(p.folder, s.folder) && s.exportProgress != null) s.exportProgress = p.progress;
    });
    try {
      s.exportedPath = await call<string>("export_start", { folder: s.folder });
    } catch (e) {
      console.error("export", e);
      s.exportError = "Export failed";
    } finally {
      s.exportProgress = null;
      exporting = false;
      off();
    }
  }
</script>

{#if store}
  {@const s = store}
  <div class="editor" style:--inset="{titleBarInset - 6}px">
    <div class="top">
      <div class="left">
        <div class="preview-zone">
          <Preview store={s} bind:playback>
            {#snippet overlay({ w, h, k })}
              {#if s.cameraPhase.kind !== "off"}
                <div class="overlay" transition:fade><CameraOverlay store={s} {w} {h} {k} /></div>
              {:else if s.framing}
                <div class="overlay" transition:fade><FrameOverlay store={s} {w} {h} /></div>
              {/if}
            {/snippet}
          </Preview>
        </div>
        <div class="bar">
          {#if s.cameraPhase.kind !== "off"}
            <CameraBar store={s} />
          {:else if s.framing}
            <FrameBar store={s} />
          {:else}
            <Transport store={s} addFootage={() => addFootage()} />
          {/if}
        </div>
      </div>
      <div class="vline"></div>
      <Inspector store={s} cursorArt={(a, b, c, d) => s.cursorArt(a, b, c, d)} onexport={startExport} />
    </div>
    <div class="hline"></div>
    <div class="timeline-zone"><Timeline store={s} /></div>
    {#if s.showingMusic}
      <div class="music" transition:fade><MusicBrowser store={s} /></div>
    {/if}
  </div>
{:else if failed}
  <div class="failed">
    <p>Monet Shot couldn't open that recording</p>
    <p class="why">{failed}</p>
  </div>
{/if}

<style>
  .editor {
    height: 100vh;
    display: flex;
    flex-direction: column;
    background: var(--charcoal);
    position: relative;
  }
  .top {
    flex: 1;
    min-height: 0;
    display: flex;
  }
  .left {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
  }
  .preview-zone {
    flex: 1;
    min-height: 0;
    display: flex;
    padding: max(var(--inset), 16px) 28px 14px;
  }
  .bar {
    padding: 0 28px 14px;
  }
  .vline {
    width: 1px;
    background: rgba(58, 62, 65, 0.6);
  }
  .hline {
    height: 1px;
    background: rgba(58, 62, 65, 0.6);
  }
  .timeline-zone {
    flex: none;
  }
  .overlay {
    position: absolute;
    inset: 0;
  }
  .music {
    position: absolute;
    inset: 0;
    z-index: 10;
  }
  .failed {
    height: 100vh;
    display: grid;
    place-content: center;
    text-align: center;
    gap: 6px;
  }
  .failed p {
    margin: 0;
    font-size: 14px;
    font-weight: 600;
  }
  .failed .why {
    font-size: 12px;
    font-weight: 400;
    color: var(--dim);
  }
</style>
