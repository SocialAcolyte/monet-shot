<script lang="ts">
  // The inspector's Captions section (CaptionsSection on the Mac): the
  // switch, Transcribe with its progress, the language, the transcript as
  // words you can click to fix, Copy transcript, and the two settings.
  import { AudioLines, Copy, Check, X } from "@lucide/svelte";
  import type { EditorStore } from "../store.svelte";
  import type { CaptionWord } from "../core";
  import Section from "../parts/Section.svelte";
  import ToggleRow from "../parts/ToggleRow.svelte";
  import Hint from "../parts/Hint.svelte";
  import { LANGUAGES } from "../speech.svelte";

  let { store }: { store: EditorStore } = $props();
  const sp = $derived(store.speech);
  const words = $derived(sp.words);
  let draft = $state("");

  function begin(w: CaptionWord) {
    sp.editing = w;
    draft = w.text;
    store.seek(w.start + 0.01);
  }
  function keydown(ev: KeyboardEvent, w: CaptionWord) {
    ev.stopPropagation();
    if (ev.key === "Enter") void sp.fix(w, draft);
    if (ev.key === "Escape") sp.editing = null;
  }
  const same = (a: CaptionWord | null, b: CaptionWord) => !!a && a.take === b.take && a.index === b.index && a.span === b.span && a.text === b.text;
  /** The word being said at the playhead. */
  const now = $derived(words.findIndex((w) => store.time >= w.start && store.time < w.end + 0.05));
  // whisper reports how far it is only between 30-second windows, so a
  // short take says nothing until it's done: no number then, and the bar
  // sweeps instead of sitting at 0%.
  const known = $derived(!!sp.busy && sp.busy.progress > 0.005);
  const pct = $derived(sp.busy ? ` ${Math.round(sp.busy.progress * 100)}%` : "");
  const status = $derived(
    sp.busy ? (sp.busy.stage === "download" ? "Getting the speech model…" : "Listening…") + (known ? pct : "") : null,
  );
</script>

<Section title="Captions">
  {#if !sp.hasVoice}
    <Hint text="Choose a microphone in the tray menu before you record, and what you say becomes captions." />
  {:else}
    <ToggleRow label="Captions" on={sp.on} onchange={(v) => sp.setOn(v)} />
    {#if sp.busy}
      <div class="busy">
        <div class="bar" class:sweep={!known} role="progressbar" aria-valuenow={known ? Math.round(sp.busy.progress * 100) : undefined}><span style:width={known ? `${Math.round(sp.busy.progress * 100)}%` : "40%"}></span></div>
        <span class="status tabular">{status}</span>
        <button class="icon" title="Stop" aria-label="Stop transcribing" onclick={() => sp.cancel()}><X size={13} /></button>
      </div>
    {:else}
      <div class="row">
        <button class="pill-button" onclick={() => sp.transcribe()}><AudioLines /> {sp.transcribed ? "Transcribe again" : "Transcribe"}</button>
        <select value={sp.settings.language} onchange={(ev) => sp.setSettings({ language: ev.currentTarget.value })} title="Language">
          {#each LANGUAGES as l (l.value)}<option value={l.value}>{l.label}</option>{/each}
        </select>
      </div>
    {/if}
    {#if sp.error}<p class="error">{sp.error}</p>{/if}
    {#if words.length}
      <div class="transcript" aria-label="Transcript">
        {#each words as w, k (`${w.span}-${w.index}-${w.text}-${k}`)}
          {#if same(sp.editing, w)}
            <!-- svelte-ignore a11y_autofocus -->
            <input class="fix" bind:value={draft} size={Math.max(2, draft.length)} autofocus onkeydown={(ev) => keydown(ev, w)} onblur={() => sp.fix(w, draft)} />
          {:else}
            <button class="word" class:now={k === now} title="Fix this word (empty it to drop it)" onclick={() => begin(w)}>{w.text}</button>
          {/if}
        {/each}
      </div>
      <Hint text="Click a word to fix it; empty it to drop a filler." />
      <button class="link" onclick={() => sp.copy()}>{#if sp.copied}<Check size={13} /> Copied{:else}<Copy size={13} /> Copy transcript{/if}</button>
    {/if}
    <ToggleRow label="Transcribe new takes" on={sp.settings.autoTranscribe} onchange={(v) => sp.setSettings({ autoTranscribe: v })} />
    <ToggleRow label="Subtitles beside exports" on={sp.settings.writeSubtitles} onchange={(v) => sp.setSettings({ writeSubtitles: v })} />
  {/if}
</Section>

<style>
  .row {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .row select {
    flex: 1;
    min-width: 0;
  }
  .busy {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .bar {
    flex: none;
    width: 56px;
    height: 3px;
    border-radius: 2px;
    background: var(--midnight);
    overflow: hidden;
  }
  .bar span {
    display: block;
    height: 100%;
    background: var(--violet);
    transition: width 0.2s linear;
  }
  .bar.sweep span {
    transition: none;
    animation: sweep 1.2s ease-in-out infinite;
  }
  @keyframes sweep {
    from {
      transform: translateX(-100%);
    }
    to {
      transform: translateX(250%);
    }
  }
  .status {
    flex: 1;
    font-size: 11.5px;
    color: var(--dim);
  }
  .icon {
    color: var(--dim);
    display: flex;
  }
  .error {
    margin: 0;
    font-size: 11.5px;
    color: #e07a55;
  }
  .transcript {
    display: flex;
    flex-wrap: wrap;
    gap: 2px 1px;
    max-height: 180px;
    overflow-y: auto;
    font-size: 12.5px;
    line-height: 1.5;
  }
  .word {
    padding: 0 3px;
    border-radius: 4px;
    color: var(--moon-white);
  }
  .word:hover {
    background: var(--midnight);
  }
  .word.now {
    color: #e07a55;
  }
  .fix {
    font: inherit;
    font-size: 12.5px;
    padding: 0 3px;
    border-radius: 4px;
    border: 1px solid var(--violet);
    background: var(--midnight);
    color: var(--moon-white);
    min-width: 2ch;
  }
  .link {
    align-self: flex-start;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 11.5px;
    font-weight: 500;
    color: var(--violet);
  }
  select {
    background: var(--midnight);
    color: var(--moon-white);
    border: none;
    border-radius: 6px;
    height: 24px;
    padding: 0 6px;
    font: inherit;
    font-size: 12px;
  }
</style>
