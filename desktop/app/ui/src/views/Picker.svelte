<script lang="ts">
  // Our own picker where the system has none for us (Windows, macos-dev):
  // displays first, then windows, each a card with its thumbnail. Linux uses
  // the portal's dialog. Esc or closing the window chooses nothing.
  import { onMount } from "svelte";
  import { call } from "../lib/ipc";
  import { fade } from "../lib/motion";

  interface SourceView {
    id: string;
    kind: "display" | "window";
    title: string;
    app: string | null;
    width: number;
    height: number;
    thumbnail: string | null;
  }

  let sources = $state<SourceView[] | null>(null);
  let failed = $state<string | null>(null);
  const displays = $derived((sources ?? []).filter((s) => s.kind === "display"));
  const windows = $derived((sources ?? []).filter((s) => s.kind === "window"));

  onMount(() => {
    call<SourceView[]>("picker_sources").then(
      (s) => (sources = s),
      (e) => (failed = String(e)),
    );
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") call("picker_choose", { id: null });
    };
    addEventListener("keydown", key);
    return () => removeEventListener("keydown", key);
  });

  const choose = (id: string) => call("picker_choose", { id });
</script>

<main>
  <header data-tauri-drag-region>
    <h1 data-tauri-drag-region>Choose what to record</h1>
    <button class="pill-button" onclick={() => call("picker_choose", { id: null })}>Cancel</button>
  </header>

  {#if failed}
    <p class="note">{failed}</p>
  {:else if sources === null}
    <p class="note">Looking for screens…</p>
  {:else}
    <div class="scroll" in:fade>
      {#each [["Displays", displays], ["Windows", windows]] as [label, list]}
        {#if (list as SourceView[]).length}
          <h2>{label}</h2>
          <div class="grid">
            {#each list as SourceView[] as s (s.id)}
              <button class="card" onclick={() => choose(s.id)}>
                <div class="thumb">
                  {#if s.thumbnail}<img src={s.thumbnail} alt="" />{/if}
                </div>
                <div class="title">{s.title}</div>
                {#if s.app}<div class="sub">{s.app}</div>{/if}
              </button>
            {/each}
          </div>
        {/if}
      {/each}
    </div>
  {/if}
</main>

<style>
  main {
    height: 100vh;
    display: flex;
    flex-direction: column;
  }
  header {
    display: flex;
    align-items: center;
    padding: 34px 28px 18px;
  }
  h1 {
    flex: 1;
    margin: 0;
    font-size: 20px;
    font-weight: 700;
  }
  h2 {
    margin: 4px 0 12px;
    font-size: 12px;
    font-weight: 600;
    color: var(--dim);
  }
  .scroll {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 0 28px 28px;
    scrollbar-width: none;
  }
  .scroll::-webkit-scrollbar {
    display: none;
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 18px;
    margin-bottom: 22px;
  }
  .card {
    text-align: left;
    display: flex;
    flex-direction: column;
    gap: 6px;
    transition: transform var(--dur-snappy) var(--ease-snappy);
  }
  .card:active {
    transform: scale(0.98);
  }
  .thumb {
    aspect-ratio: 16 / 9;
    border-radius: 10px;
    background: var(--panel);
    overflow: hidden;
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.07);
    display: grid;
    place-items: center;
    transition: box-shadow var(--dur-base) var(--ease-base);
  }
  .card:hover .thumb {
    box-shadow: inset 0 0 0 2px var(--violet);
  }
  .thumb img {
    width: 100%;
    height: 100%;
    object-fit: contain;
  }
  .title {
    font-size: 13px;
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .sub {
    font-size: 12px;
    color: var(--dim);
  }
  .note {
    padding: 0 28px;
    color: var(--dim);
  }
</style>
