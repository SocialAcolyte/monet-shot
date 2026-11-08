<script lang="ts">
  // The right-hand column (InspectorView): the selected clip, zoom, hide &
  // crop, music, the frame, the cursor, the camera, the output, and Export at
  // the foot. Every control writes straight to the edit.
  import { onMount } from "svelte";
  import { Trash2, Scissors, EyeOff, Crop, Image as ImageIcon, ImagePlus, Check, Music, Type, Captions, Tag } from "@lucide/svelte";
  import Section from "../parts/Section.svelte";
  import Hint from "../parts/Hint.svelte";
  import SliderRow from "../parts/SliderRow.svelte";
  import ToggleRow from "../parts/ToggleRow.svelte";
  import Segmented from "../parts/Segmented.svelte";
  import CursorTile from "../parts/CursorTile.svelte";
  import MusicSection from "../music/MusicSection.svelte";
  import CameraSection from "../camera/CameraSection.svelte";
  import CaptionsSection from "./CaptionsSection.svelte";
  import type { EditorStore } from "../store.svelte";
  import { SPEEDS, TEXT_ANIMATIONS, TEXT_STYLES, TEXT_TONES, hasBacking, outputDuration, rate, speedLabel, type Edit, type Format } from "../core";
  import { moods } from "../music/music";
  import type { CursorArt } from "../plan";
  import { stamp, percent } from "../format";
  import { call, inTauri } from "../../lib/ipc";
  import { fileUrl } from "../../lib/files";
  import { fileManager } from "../../lib/platform";

  let {
    store,
    cursorArt,
    onexport,
  }: { store: EditorStore; cursorArt: (style: string, tint: string, label: string, h: number) => CursorArt | null; onexport: () => void } = $props();

  interface Painting { file: string; title: string; artist: string; path: string; thumb: string }
  let paintings = $state<Painting[]>([]);
  onMount(() => {
    call<Painting[]>("backdrop_gallery").then((p) => (paintings = p), () => {});
  });

  const e = $derived(store.edit);
  const set = <K extends keyof Edit>(k: K, v: Edit[K]) => store.update((d) => void (d[k] = v));

  const backdrops = [
    { id: "paper", label: "Paper", fill: "#F3F0E8" },
    { id: "charcoal", label: "Charcoal", fill: "linear-gradient(to bottom, #303336, #17191B)" },
    { id: "dusk", label: "Dusk", fill: "linear-gradient(to bottom right, #B8694A, #2B211C)" },
    { id: "slate", label: "Slate", fill: "linear-gradient(to bottom right, #6E8088, #252C30)" },
    { id: "none", label: "None", fill: "#000" },
  ];
  const styles = [
    { id: "classic", label: "Classic" },
    { id: "white", label: "White" },
    { id: "soft", label: "Soft" },
    { id: "dot", label: "Dot" },
    { id: "tag", label: "Name tag" },
  ];
  const tints: [string, string][] = [
    ["clay", "#E07A55"],
    ["sky", "#5F9FD8"],
    ["mint", "#4FB38E"],
    ["butter", "#E8B53E"],
    ["lilac", "#9584DB"],
    ["rose", "#E07C9E"],
  ];
  const tinted = (s: string) => s === "soft" || s === "dot" || s === "tag";

  function clipHint(i: number) {
    const c = store.clips[i];
    const take = store.takes.length > 1 ? `Take ${c.take + 1}, ` : "";
    const at = rate(c) !== 1 ? ` at ${speedLabel(rate(c))}` : "";
    return `${take}${stamp(c.start)} to ${stamp(c.end)}, ${outputDuration(c).toFixed(1)} s${at}. Drag its ends to trim it, or its middle to move it. ${navigator.platform.includes("Mac") ? "⌘Z" : "Ctrl+Z"} undoes.`;
  }

  /** The step nearest a speed (the Speed slider runs over SPEEDS). */
  const speedStep = (r: number) => SPEEDS.reduce((best, v, k) => (Math.abs(v - r) < Math.abs(SPEEDS[best] - r) ? k : best), 0);
  const fadeLabel = (v: number) => (v === 0 ? "Cut" : `${v.toFixed(1)} s`);

  // Formats: each card hints at its backdrop and its pace (FormatCard).
  const cardFill: Record<string, string> = { paper: "#e9e4d8", charcoal: "#26292c", dusk: "#7a4a36", slate: "#46555c" };
  const formatBackdrop: Record<string, string> = { clean: "paper", fast: "slate", melancholic: "dusk", cinematic: "charcoal" };
  const paceLine = (f: Format) => `${speedLabel(f.speed)} · ${f.clipFade > 0 ? "fades" : "cuts"}`;
  const moodName = (f: Format) => moods.find((m) => m.id === f.musicMood)?.name.toLowerCase();
  const textPlace = (y: number) => (y < 0.33 ? 0 : y < 0.7 ? 1 : 2);

  function privacyHint() {
    const n = e.blurs.length;
    const cropped = e.crops.length > 0;
    if (n === 0 && !cropped) return "Blur a chat or an inbox out of the video, or crop the screen down to what matters.";
    const parts = [n > 0 ? `${n} part${n === 1 ? "" : "s"} hidden` : null, cropped ? "cropped" : null].filter(Boolean);
    return parts.join(", ") + (store.framing ? ". Select a box to change it." : ".");
  }

  function blurHint(b: NonNullable<typeof store.selectedBlur>) {
    const always = b.start == null && b.end == null;
    return always
      ? "Hidden for the whole take. Move the playhead and set a start or end to hide it only for a while."
      : `Hidden from ${b.start != null ? stamp(b.start) : "the start"} to ${b.end != null ? stamp(b.end) : "the end"} of the take.`;
  }

  async function ownPicture() {
    if (!inTauri) return;
    const { open } = await import("@tauri-apps/plugin-dialog");
    const path = await open({
      title: "Choose a picture for the background",
      filters: [{ name: "Pictures", extensions: ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp", "tif", "tiff"] }],
    });
    if (typeof path === "string") store.setBackdropImage(path);
  }

  function imageSwatch() {
    if (e.backdropImage) set("backdrop", "image");
    else if (paintings[0]) store.setBackdropImage(paintings[0].path, `backdrop-${paintings[0].file}`);
    else ownPicture();
  }

  const canvasSize = $derived(store.c.canvasSize(e, (store.takes[0]?.meta.pixelWidth ?? 16) / (store.takes[0]?.meta.pixelHeight ?? 9)));
  const aspect = $derived(e.canvasAspect === 0 ? 0 : Math.abs(e.canvasAspect - 1) < 0.01 ? 1 : 16 / 9);

</script>

<div class="inspector">
  <div class="scroll">
    <Section title="Format">
      <div class="formats">
        {#each store.formats as f (f.id)}
          {@const paper = formatBackdrop[f.id] === "paper"}
          <button class="format" class:on={e.format === f.id} class:paper style:background={cardFill[formatBackdrop[f.id]]} title={f.blurb} onclick={() => store.applyFormat(f.id)}>
            <span class="pace">{#each Array(Math.round(4 * f.speed)) as _, k (k)}<span class:soft={f.clipFade > 0}></span>{/each}</span>
            <span class="fname">{f.name}</span>
            <span class="fline tabular">{paceLine(f)}</span>
          </button>
        {/each}
      </div>
      {#if store.format}
        {@const f = store.format}
        <Hint text={f.blurb} />
        {#if moodName(f)}<button class="link" onclick={() => store.findMusic(f)}><Music size={13} /> Find {moodName(f)} music</button>{/if}
      {:else}
        <Hint text="Sets the pace and the look in one go: speed, cuts or fades, zooms, backdrop and how words come in. Everything stays adjustable." />
      {/if}
    </Section>

    {#if store.selectedClip != null && store.clips[store.selectedClip]}
      {@const i = store.selectedClip}
      <Section title="Clip {i + 1} of {store.clips.length}">
        {@const c = store.clips[i]}
        <Hint text={clipHint(i)} />
        <SliderRow
          label="Speed"
          value={speedStep(rate(c))}
          min={0}
          max={SPEEDS.length - 1}
          format={() => speedLabel(rate(c))}
          onchange={(v) => {
            const s = SPEEDS[Math.round(v)];
            if (s !== rate(c)) store.setSpeed(s, i);
          }}
        />
        <div class="row chips">
          {#each [0.5, 1, 1.5, 2, 4] as v (v)}
            <button class="chip tabular" class:on={rate(c) === v} onclick={() => store.setSpeed(v, i)}>{speedLabel(v)}</button>
          {/each}
          {#if store.clips.length > 1}
            <button class="link" onclick={() => store.setSpeedForAll(rate(c))} title="Play every clip at {speedLabel(rate(c))}">All clips</button>
          {/if}
        </div>
        <SliderRow label="Fade in" value={c.fadeIn ?? 0} min={0} max={2} format={fadeLabel} onchange={(v) => store.setFades(i, { fadeIn: v < 0.05 ? 0 : v })} />
        <SliderRow label="Fade out" value={c.fadeOut ?? 0} min={0} max={2} format={fadeLabel} onchange={(v) => store.setFades(i, { fadeOut: v < 0.05 ? 0 : v })} />
        <div class="row">
          <button class="pill-button" onclick={() => store.split()} title="Split at the playhead (S)"><Scissors /> Split</button>
          <button class="pill-button" onclick={() => store.deleteClip(i)} disabled={store.clips.length < 2} title="Leave this clip out (Delete)"><Trash2 /> Delete</button>
        </div>
      </Section>
    {/if}

    <Section title="Text">
      {#if store.selectedText}
        {@const o = store.selectedText}
        <textarea class="words" rows={Math.min(4, Math.max(1, o.text.split("\n").length))} value={o.text} oninput={(ev) => store.setText(o.id, (x) => (x.text = ev.currentTarget.value))}></textarea>
        <Segmented options={TEXT_STYLES.map((t) => ({ ...t }))} value={o.style} onchange={(v) => store.setText(o.id, (x) => { x.style = v; delete x.backing; })} />
        <div class="row between">
          <span class="label">Comes in</span>
          <select value={o.animation} onchange={(ev) => store.setText(o.id, (x) => (x.animation = ev.currentTarget.value as typeof x.animation))}>
            {#each TEXT_ANIMATIONS as a (a.value)}<option value={a.value}>{a.label}</option>{/each}
          </select>
        </div>
        <div class="row chips">
          {#each TEXT_TONES as t (t.value)}
            <button class="chip" class:on={o.tone === t.value} onclick={() => store.setText(o.id, (x) => (x.tone = t.value))}>{t.label}</button>
          {/each}
        </div>
        <Segmented
          options={[{ value: 0, label: "Top" }, { value: 1, label: "Middle" }, { value: 2, label: "Bottom" }]}
          value={textPlace(o.y)}
          onchange={(v) => store.setText(o.id, (x) => { x.x = 0.5; x.y = [0.16, 0.45, 0.86][v]; })}
        />
        <SliderRow label="Size" value={o.size} min={0.5} max={2.5} format={(v) => `${v.toFixed(1)}×`} onchange={(v) => store.setText(o.id, (x) => (x.size = v))} />
        <ToggleRow label="Capitals" on={o.uppercase} onchange={(v) => store.setText(o.id, (x) => (x.uppercase = v))} />
        <ToggleRow label="Box behind" on={hasBacking(o)} onchange={(v) => store.setText(o.id, (x) => (x.backing = v))} />
        <Hint text="{stamp(o.at)} to {stamp(o.at + o.duration)}. Drag it on the timeline, or move the playhead and set an end." />
        <div class="row">
          <button class="pill-button" onclick={() => store.textStartsHere(o.id)}>Start here</button>
          <button class="pill-button" onclick={() => store.textEndsHere(o.id)}>End here</button>
          <button class="pill-button push" onclick={() => store.deleteText(o.id)} title="Delete this text (Delete)" aria-label="Delete this text"><Trash2 /></button>
        </div>
      {:else}
        <Hint text="Words over the video, on their own lane. T adds a title at the playhead." />
        <div class="row">
          <button class="pill-button" onclick={() => store.addText("title")}><Type /> Title</button>
          <button class="pill-button" onclick={() => store.addText("caption")}><Captions /> Caption</button>
          <button class="pill-button" onclick={() => store.addText("label")}><Tag /> Label</button>
        </div>
      {/if}
    </Section>

    <CaptionsSection {store} />

    <Section title="Zoom">
      {#if store.selected}
        {@const seg = store.selected}
        <SliderRow label="Depth" value={seg.scale} min={1.2} max={4} format={(v) => `${v.toFixed(1)}×`} onchange={(v) => store.setSelected((s) => (s.scale = v))} />
        <Segmented
          options={[{ value: true, label: "Follow cursor" }, { value: false, label: "Hold still" }]}
          value={seg.focusX == null}
          onchange={(follow) => {
            if (follow) store.setFocus(null);
            else store.setFocus(store.cameraCentre(Math.max(seg.start, Math.min(store.time, seg.end))));
          }}
        />
        {#if seg.focusX != null}<Hint text="Click the preview to choose where it looks." />{/if}
        <div class="row"><button class="pill-button" onclick={() => store.deleteSelected()}><Trash2 /> Remove zoom</button></div>
      {:else}
        <Hint text={e.segments.length === 0 ? "No zooms yet. Auto zoom finds your clicks; Z adds one at the playhead." : "Select a zoom on the timeline to change it."} />
      {/if}
    </Section>

    <Section title="Hide & crop">
      {#if store.selectedBlur}
        {@const b = store.selectedBlur}
        <Segmented
          options={[{ value: "blur" as const, label: "Blur" }, { value: "pixelate" as const, label: "Pixelate" }, { value: "solid" as const, label: "Cover" }]}
          value={b.style}
          onchange={(v) => store.setBlur(b.id, (x) => (x.style = v))}
        />
        {#if b.style !== "solid"}
          <SliderRow label="Strength" value={b.strength} min={0} max={1} format={percent} onchange={(v) => store.setBlur(b.id, (x) => (x.strength = v))} />
        {/if}
        <Hint text={blurHint(b)} />
        <div class="row">
          <button class="pill-button" onclick={() => store.setBlurEdge(true)} title="Hide it from the playhead on">Start here</button>
          <button class="pill-button" onclick={() => store.setBlurEdge(false)} title="Stop hiding it at the playhead">End here</button>
          {#if b.start != null || b.end != null}
            <button class="pill-button" onclick={() => store.blurAlways()} title="Hide it for the whole take">Always</button>
          {/if}
        </div>
        <div class="row"><button class="pill-button" onclick={() => store.deleteBlur(b.id)}><Trash2 /> Remove</button></div>
      {:else}
        <Hint text={privacyHint()} />
        {#if !store.framing}
          <div class="row">
            <button class="pill-button" onclick={() => store.openFraming("blur")} title="Draw boxes over what shouldn't be seen (B)"><EyeOff /> Hide…</button>
            <button class="pill-button" onclick={() => store.openFraming("crop")} title="Keep only part of the screen"><Crop /> Crop…</button>
          </div>
        {/if}
      {/if}
    </Section>

    <MusicSection {store} />

    <Section title="Frame">
      <div class="swatches">
        {#each backdrops as b (b.id)}
          <button class="swatch" class:sel={e.backdrop === b.id} title={b.label} aria-label={b.label} onclick={() => set("backdrop", b.id)}>
            <span class="disc" style:background={b.fill}>
              {#if b.id === "none"}<span class="slash"></span>{/if}
            </span>
          </button>
        {/each}
        <button
          class="swatch"
          class:sel={e.backdrop === "image"}
          title={e.backdropImage ? "Picture" : "Use a painting, or a picture of your own"}
          aria-label="Picture"
          onclick={imageSwatch}
        >
          <span class="disc pic">
            {#if e.backdropImage}<img src={fileUrl(`${store.folder}/${e.backdropImage}`)} alt="" />{:else}<ImagePlus size={11} />{/if}
          </span>
        </button>
      </div>
      {#if e.backdrop === "image"}
        {#if paintings.length}
          <div class="gallery">
            {#each paintings as p (p.file)}
              <button
                class="painting"
                class:sel={e.backdropImage === `backdrop-${p.file}`}
                title="{p.title}, {p.artist}"
                onclick={() => store.setBackdropImage(p.path, `backdrop-${p.file}`)}
              >
                <img src={fileUrl(p.thumb)} alt={p.title} loading="lazy" />
              </button>
            {/each}
          </div>
        {/if}
        <SliderRow label="Blur" value={e.backdropBlur} min={0} max={1} format={percent} onchange={(v) => set("backdropBlur", v)} />
        <div class="row"><button class="pill-button" onclick={ownPicture}><ImageIcon /> Your own picture…</button></div>
      {/if}
      {#if e.backdrop !== "none"}
        <SliderRow label="Padding" value={e.padding} min={0} max={0.16} format={(v) => `${Math.round(v * 100)}`} onchange={(v) => set("padding", v)} />
        <SliderRow label="Corners" value={e.cornerRadius} min={0} max={0.05} format={(v) => `${Math.round(v * 1000)}`} onchange={(v) => set("cornerRadius", v)} />
        <ToggleRow label="Shadow" on={e.shadow} onchange={(v) => set("shadow", v)} />
      {/if}
    </Section>

    <Section title="Cursor">
      <ToggleRow label="Show cursor" on={e.cursorVisible} onchange={(v) => set("cursorVisible", v)} />
      {#if e.cursorVisible}
        <div class="cursors">
          {#each styles as s (s.id)}
            <button title={s.label} aria-label={s.label} onclick={() => set("cursorStyle", s.id)}>
              <CursorTile art={cursorArt(s.id, e.cursorTint, "Hi", 40)} selected={e.cursorStyle === s.id} tag={s.id === "tag"} />
            </button>
          {/each}
        </div>
        {#if tinted(e.cursorStyle)}
          <div class="tints">
            {#each tints as [id, hex] (id)}
              <button class="tint" class:sel={e.cursorTint === id} title={id[0].toUpperCase() + id.slice(1)} aria-label={id} onclick={() => set("cursorTint", id)}>
                <span style:background={hex}></span>
              </button>
            {/each}
          </div>
        {/if}
        {#if e.cursorStyle === "tag"}
          <input class="field" placeholder="Your name" value={e.cursorLabel} oninput={(ev) => set("cursorLabel", (ev.currentTarget as HTMLInputElement).value)} />
        {/if}
        <SliderRow label="Size" value={e.cursorScale} min={0.8} max={3} format={(v) => `${v.toFixed(1)}×`} onchange={(v) => set("cursorScale", v)} />
        <SliderRow label="Smoothing" value={e.cursorSmoothing} min={0} max={1} format={percent} onchange={(v) => set("cursorSmoothing", v)} />
        <ToggleRow label="Click ripples" on={e.clickRipple} onchange={(v) => set("clickRipple", v)} />
      {/if}
    </Section>

    <CameraSection {store} />

    <Section title="Output">
      <Segmented
        options={[{ value: 1920, label: "1080p" }, { value: 2560, label: "1440p" }, { value: 3840, label: "4K" }]}
        value={e.outputWidth}
        onchange={(v) => set("outputWidth", v)}
      />
      <Segmented
        options={[{ value: 16 / 9, label: "16:9" }, { value: 1, label: "Square" }, { value: 0, label: "As recorded" }]}
        value={aspect}
        onchange={(v) => set("canvasAspect", v)}
      />
      <Hint text="{canvasSize.width} × {canvasSize.height}, 60 fps" />
    </Section>
  </div>

  <div class="foot">
    {#if store.exportProgress != null}
      <div class="progress">
        <span class="fill" style:width="max(18px, {store.exportProgress * 100}%)"></span>
        <span class="label tabular">Exporting {Math.round(store.exportProgress * 100)}%</span>
      </div>
    {:else}
      <button class="pill-button prominent wide" onclick={onexport} title="Render the video next to the recording (Ctrl+E)">Export MP4</button>
    {/if}
    {#if store.exportedPath && store.exportProgress == null}
      <button class="link" onclick={() => call("reveal", { path: store.exportedPath })} title="Show in {fileManager}">
        <Check size={12} /> <span class="name">{store.exportedPath.split(/[\\/]/).pop()}</span>
      </button>
    {/if}
    {#if store.exportError}<p class="error">{store.exportError}</p>{/if}
  </div>
</div>

<style>
  .inspector {
    width: 284px;
    flex: none;
    display: flex;
    flex-direction: column;
    background: var(--panel);
    min-height: 0;
  }
  .scroll {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 42px 20px 20px;
    display: flex;
    flex-direction: column;
    gap: 26px;
    scrollbar-width: none;
  }
  .scroll::-webkit-scrollbar {
    display: none;
  }
  .foot {
    border-top: 1px solid rgba(58, 62, 65, 0.6);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .wide {
    width: 100%;
    justify-content: center;
  }
  .chips {
    gap: 6px;
  }
  .between {
    justify-content: space-between;
  }
  .push {
    margin-left: auto;
  }
  .label {
    font-size: 12px;
    color: var(--moon-white);
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
  .words {
    width: 100%;
    box-sizing: border-box;
    resize: none;
    background: var(--midnight);
    color: var(--moon-white);
    border: 1px solid var(--line);
    border-radius: 7px;
    padding: 6px 8px;
    font: inherit;
    font-size: 12.5px;
  }
  /* The formats, two by two; the edit's own is lit (FormatCard). */
  .formats {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
  }
  .format {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
    padding: 10px;
    border-radius: 10px;
    color: var(--moon-white);
    text-align: left;
    box-shadow: inset 0 0 0 1.8px transparent;
    transition: transform var(--dur-snappy) var(--ease-snappy);
  }
  .format.paper {
    color: var(--charcoal);
  }
  .format.on {
    box-shadow: inset 0 0 0 1.8px var(--violet);
    transform: scale(1.02);
  }
  .pace {
    display: flex;
    gap: 2px;
    width: 100%;
    height: 10px;
  }
  .pace span {
    flex: 1;
    border-radius: 2px;
    background: currentColor;
    opacity: 0.6;
  }
  .pace span.soft {
    opacity: 0.33;
  }
  .fname {
    font-size: 12px;
    font-weight: 600;
  }
  .fline {
    font-size: 10px;
    font-weight: 500;
    opacity: 0.65;
  }
  @media (prefers-reduced-motion: reduce) {
    .format.on {
      transform: none;
    }
  }
  .chips .link {
    margin-left: auto;
  }
  /* A small rounded choice, filled when it's the one in use (ChipStyle). */
  .chip {
    flex: none;
    height: 22px;
    padding: 0 8px;
    border-radius: 11px;
    background: var(--midnight);
    color: var(--moon-white);
    font-size: 11px;
    font-weight: 600;
  }
  .chip.on {
    background: var(--violet);
    color: #17191b;
  }
  .link {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 11.5px;
    font-weight: 500;
    color: var(--violet);
    max-width: 100%;
  }
  .link .name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .error {
    margin: 0;
    font-size: 11.5px;
    color: var(--clay);
  }
  .progress {
    position: relative;
    height: 34px;
    border-radius: 9px;
    background: var(--midnight);
    overflow: hidden;
  }
  .progress .fill {
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    border-radius: 9px;
    background: rgba(166, 187, 195, 0.45);
    transition: width var(--dur-base) var(--ease-base);
  }
  .progress .label {
    position: absolute;
    left: 12px;
    top: 50%;
    transform: translateY(-50%);
    font-size: 12.5px;
    font-weight: 600;
  }
  .swatches {
    display: flex;
    gap: 8px;
  }
  .swatch {
    padding: 3px;
    border-radius: 50%;
    box-shadow: inset 0 0 0 1.6px transparent;
    transition:
      box-shadow var(--dur-snappy) var(--ease-snappy),
      transform var(--dur-snappy) var(--ease-snappy);
  }
  .swatch.sel {
    box-shadow: inset 0 0 0 1.6px var(--violet);
    transform: scale(1.04);
  }
  .disc {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    display: grid;
    place-items: center;
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.12);
    position: relative;
    overflow: hidden;
    color: var(--dim);
  }
  .disc.pic {
    background: var(--midnight);
  }
  .disc img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .slash {
    width: 12px;
    height: 1.5px;
    background: var(--dim);
    transform: rotate(-45deg);
  }
  .gallery {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 5px;
  }
  .painting {
    padding: 2px;
    border-radius: 6px;
    box-shadow: inset 0 0 0 1.6px transparent;
    transition: box-shadow var(--dur-snappy) var(--ease-snappy);
  }
  .painting.sel {
    box-shadow: inset 0 0 0 1.6px var(--violet);
  }
  .painting img {
    display: block;
    width: 100%;
    aspect-ratio: 16 / 10;
    object-fit: cover;
    border-radius: 4px;
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.12);
  }
  .cursors {
    display: flex;
    gap: 6px;
  }
  .tints {
    display: flex;
    gap: 8px;
  }
  .tint {
    padding: 3px;
    border-radius: 50%;
    box-shadow: inset 0 0 0 1.6px transparent;
  }
  .tint.sel {
    box-shadow: inset 0 0 0 1.6px var(--violet);
  }
  .tint span {
    display: block;
    width: 16px;
    height: 16px;
    border-radius: 50%;
  }
  .field {
    height: 26px;
    padding: 0 9px;
    border: 0;
    border-radius: 8px;
    background: var(--midnight);
    color: var(--moon-white);
    font: inherit;
    font-size: 12px;
    outline: none;
  }
  .field:focus {
    box-shadow: 0 0 0 1.5px var(--violet);
  }
</style>
