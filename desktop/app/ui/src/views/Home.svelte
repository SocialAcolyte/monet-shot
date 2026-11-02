<script lang="ts">
  // The recordings, as cards (HomeView). Opens at launch and from the tray,
  // so any edit can be reopened without recording.
  import { onMount } from "svelte";
  import { Download, CircleDot } from "@lucide/svelte";
  import Aperture from "../components/Aperture.svelte";
  import Spinner from "../components/Spinner.svelte";
  import { call, on, inTauri } from "../lib/ipc";
  import { fileUrl, minutes } from "../lib/files";
  import { fileManager, trashName, ringHome, titleBarInset } from "../lib/platform";

  interface Item {
    path: string;
    title: string;
    duration: number;
    clips: number;
    takes: number;
  }

  let items = $state<Item[]>([]);
  let thumbs = $state<Record<string, string>>({});
  let importing = $state(false);
  let loaded = $state(false);

  async function refresh() {
    items = await call<Item[]>("home_items");
    loaded = true;
    // One at a time, in order, as the Mac's loadThumbs.
    for (const it of items) {
      const p = await call<string | null>("home_thumb", { path: it.path });
      if (p) thumbs[it.path] = fileUrl(p, Date.now());
    }
  }

  onMount(() => {
    refresh();
    const off = on("library-changed", () => refresh());
    const focus = () => refresh();
    addEventListener("focus", focus);
    return () => {
      off.then((f) => f());
      removeEventListener("focus", focus);
    };
  });

  function subtitle(it: Item) {
    const parts = [minutes(it.duration)];
    if (it.clips > 1) parts.push(`${it.clips} clips`);
    if (it.takes > 1) parts.push(`${it.takes} takes`);
    return parts.join(" · ");
  }

  async function importVideo() {
    if (!inTauri) return;
    const { open } = await import("@tauri-apps/plugin-dialog");
    const path = await open({
      title: "Choose a video to edit in Monet Shot",
      filters: [{ name: "Video", extensions: ["mp4", "mov", "m4v", "mkv", "webm", "avi"] }],
    });
    if (typeof path !== "string") return;
    importing = true;
    try {
      await call("import_video", { path });
    } catch (e) {
      console.error("import", e);
    } finally {
      importing = false;
    }
  }

  const openItem = (it: Item) => call("open_recording", { path: it.path });

  async function menu(e: MouseEvent, it: Item) {
    e.preventDefault();
    if (!inTauri) return;
    const { Menu, MenuItem, PredefinedMenuItem } = await import("@tauri-apps/api/menu");
    const m = await Menu.new({
      items: [
        await MenuItem.new({ text: "Open", action: () => openItem(it) }),
        await MenuItem.new({ text: `Show in ${fileManager}`, action: () => call("reveal", { path: it.path }) }),
        await PredefinedMenuItem.new({ item: "Separator" }),
        await MenuItem.new({
          text: `Move to ${trashName}`,
          action: async () => {
            await call("trash", { path: it.path });
            delete thumbs[it.path];
          },
        }),
      ],
    });
    await m.popup();
  }
</script>

<main style:--inset="{titleBarInset}px">
  <header data-tauri-drag-region>
    <span class="mark"><Aperture size={24} /></span>
    <h1 data-tauri-drag-region>Monet Shot</h1>
    <span class="spacer" data-tauri-drag-region></span>
    <button class="pill-button" onclick={importVideo} disabled={importing} title="Edit any video in Monet Shot">
      {#if importing}<Spinner size={12} /> Importing{:else}<Download /> Import video{/if}
    </button>
    <button class="pill-button prominent" onclick={() => call("bar_tap")}><CircleDot /> New recording</button>
  </header>

  {#if loaded && items.length === 0}
    <div class="empty">
      <Aperture size={54} busy />
      <div class="big">Nothing recorded yet</div>
      <div class="small">Click the ring in the {ringHome}, or New recording.</div>
    </div>
  {:else}
    <div class="scroll">
      <div class="grid">
        {#each items as it (it.path)}
          <button class="card" onclick={() => openItem(it)} oncontextmenu={(e) => menu(e, it)}>
            <div class="thumb">
              {#if thumbs[it.path]}
                <img src={thumbs[it.path]} alt="" />
              {:else}
                <Spinner />
              {/if}
            </div>
            <div class="text">
              <div class="title">{it.title}</div>
              <div class="sub">{subtitle(it)}</div>
            </div>
          </button>
        {/each}
      </div>
    </div>
  {/if}
</main>

<style>
  main {
    height: 100vh;
    display: flex;
    flex-direction: column;
    background: var(--charcoal);
  }
  header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: var(--inset) 32px 24px;
  }
  .mark {
    display: flex;
  }
  h1 {
    margin: 0;
    font-size: 28px;
    font-weight: 700;
    letter-spacing: -0.2px;
  }
  .spacer {
    flex: 1;
    align-self: stretch;
  }
  .scroll {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 0 32px 32px;
    scrollbar-width: none;
  }
  .scroll::-webkit-scrollbar {
    display: none;
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
    column-gap: 22px;
    row-gap: 26px;
  }
  .card {
    display: flex;
    flex-direction: column;
    gap: 10px;
    text-align: left;
  }
  .thumb {
    aspect-ratio: 16 / 9;
    border-radius: 10px;
    background: var(--panel);
    overflow: hidden;
    display: grid;
    place-items: center;
    position: relative;
  }
  .thumb::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: 10px;
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.07);
    pointer-events: none;
  }
  .thumb img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .text {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .title {
    font-size: 14px;
    font-weight: 600;
  }
  .sub {
    font-size: 12px;
    color: var(--dim);
  }
  .empty {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 14px;
  }
  .big {
    font-size: 16px;
    font-weight: 600;
  }
  .small {
    font-size: 13px;
    color: var(--dim);
  }
</style>
