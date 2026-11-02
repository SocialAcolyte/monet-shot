// Everything the editor window shows and does (EditorModel on the Mac).
// Views read it and call its methods; nothing else changes it. Every edit
// re-plans through core-wasm (so the preview is the real render) and saves
// edit.json shortly after.
//
// Times are output times (the finished video's clock) unless a name says
// take time: the video is clips from one or more takes, in order.

import { call } from "../lib/ipc";
import { core, type Core, type Editor, type Edit, type Clip, type ZoomSegment, type BlurRegion, type CameraClip, type NormRect, type MusicChoice } from "./core";
import type { CursorArt, Rect } from "./plan";
import * as cameraFlow from "./camera/flow";

export interface TakeData {
  meta: { pixelWidth: number; pixelHeight: number; duration: number; source: string; camera?: string | null; [k: string]: unknown };
  cursor: { samples: unknown[]; clicks: { t: number; x: number; y: number }[] };
  dir: string;
  video: string;
  camera: string | null;
}

export interface EditorData {
  folder: string;
  name: string;
  title: string;
  edit: Edit;
  takes: TakeData[];
}

export type FrameTool = "crop" | "blur";
export type CameraPhase =
  | { kind: "off" }
  | { kind: "ready" }
  | { kind: "countdown"; n: number }
  | { kind: "recording"; since: number }
  | { kind: "saving" };

export interface ZoomPlacement {
  segment: ZoomSegment;
  start: number;
  end: number;
  clip: number;
  id: string;
}

/** Frames per second the editor steps by (Composer.fps). */
export const FPS = 60;

const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v));
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

export class EditorStore {
  folder: string;
  name: string;
  title: string;
  takes = $state<TakeData[]>([]);

  /** The edit (edit.json). Replaced, never mutated in place. */
  edit = $state<Edit>(null as unknown as Edit);
  /** Bumped whenever the planner changes, so views re-ask it. */
  version = $state(0);

  time = $state(0);
  playing = $state(false);
  selectedID = $state<string | null>(null);
  selectedClip = $state<number | null>(null);
  selectedBlurID = $state<string | null>(null);
  canUndo = $state(false);
  canRedo = $state(false);

  /** The clip being moved and how far (output seconds) it has been dragged. */
  moving = $state<{ index: number; offset: number } | null>(null);

  framing = $state(false);
  frameTool = $state<FrameTool>("blur");
  /** A box being drawn on the preview (view coordinates), shown until let go. */
  drawingBox = $state<Rect | null>(null);

  cameraPhase = $state<CameraPhase>({ kind: "off" });
  /** Record a clip of just you (added at the end) instead of over the video. */
  cameraAlone = $state(false);

  /** The edit plays silent (the camera records over it). */
  muted = $state(false);

  showingMusic = $state(false);
  musicWave = $state<number[]>([]);
  musicGrid = $state<{ bar: number; lifts: number[]; [k: string]: unknown } | null>(null);

  /** null when idle; 0...1 while exporting. */
  exportProgress = $state<number | null>(null);
  exportedPath = $state<string | null>(null);
  exportError = $state<string | null>(null);

  readonly c: Core;
  private ed: Editor;
  private undoStack: Edit[] = [];
  private redoStack: Edit[] = [];
  private lastCheckpoint = 0;
  private saveTimer = 0;
  /** The edit has changes not yet written. */
  private unsaved = false;
  private dragOrigin: ZoomSegment | null = null;
  private clipOrigin: { index: number; leading: boolean; clips: Clip[] } | null = null;
  private musicOrigin: number | null = null;
  /** A box as it was when a drag on it began (drags are relative to that). */
  boxOrigin: NormRect | null = null;

  private constructor(c: Core, data: EditorData) {
    this.c = c;
    this.folder = data.folder;
    this.name = data.name;
    this.title = data.title;
    this.takes = data.takes;
    this.ed = new c.Editor(data.edit, data.takes);
    this.edit = this.ed.edit();
  }

  static async open(folder: string): Promise<EditorStore> {
    const [c, data] = await Promise.all([core(), call<EditorData>("editor_load", { path: folder })]);
    return new EditorStore(c, data);
  }

  // MARK: derived (re-read after every edit through `version`)

  /** Length of the finished video. */
  get duration(): number {
    void this.version;
    return this.ed.duration();
  }
  /** The clips, in play order. */
  get clips(): Clip[] {
    void this.version;
    return this.ed.clips();
  }
  get starts(): number[] {
    void this.version;
    return this.ed.starts();
  }
  get canvas() {
    void this.version;
    return this.ed.canvasSize();
  }
  get editor(): Editor {
    void this.version;
    return this.ed;
  }
  takeDuration(take: number): number {
    return this.takes[take]?.meta.duration ?? 0;
  }
  get selected(): ZoomSegment | null {
    return this.edit.segments.find((s) => s.id === this.selectedID) ?? null;
  }
  get selectedBlur(): BlurRegion | null {
    return this.edit.blurs.find((b) => b.id === this.selectedBlurID) ?? null;
  }

  /** Where each zoom shows on the timeline: every part of it some clip plays. */
  get zoomPlacements(): ZoomPlacement[] {
    void this.version;
    const out: ZoomPlacement[] = [];
    this.ed.spans().forEach((span, i) => {
      for (const seg of this.edit.segments) {
        if (seg.take !== span.take || seg.end <= span.start || seg.start >= span.end) continue;
        const a = Math.max(seg.start, span.start), b = Math.min(seg.end, span.end);
        out.push({ segment: seg, start: span.at + (a - span.start), end: span.at + (b - span.start), clip: i, id: `${seg.id}-${i}` });
      }
    });
    return out;
  }

  /** Where each zoom begins in the finished video. */
  get zoomMoments(): number[] {
    void this.version;
    return this.edit.segments
      .map((s) => this.ed.output(s.take, s.start))
      .filter((t): t is number => t != null)
      .sort((a, b) => a - b);
  }

  // MARK: transport (the preview's clock reads and sets these)

  togglePlay() {
    if (this.playing) {
      this.playing = false;
    } else {
      if (this.time >= this.duration - 0.05) this.seek(0);
      this.playing = true;
    }
  }

  seek(t: number) {
    this.time = Math.min(Math.max(0, t), this.duration);
  }

  step(frames: number) {
    if (this.playing) this.togglePlay();
    this.seek(this.time + frames / FPS);
  }

  // MARK: edits

  update(change: (e: Edit) => void) {
    const next = clone(this.edit);
    change(next);
    if (same(next, this.edit)) return;
    this.checkpoint();
    this.apply(next);
  }

  private apply(next: Edit) {
    this.edit = next;
    this.replan();
    this.scheduleSave();
  }

  /** The planner sees the edit as the preview shows it: while framing,
   *  uncropped, unzoomed and without the cursor (EditorModel.shown). */
  private replan() {
    const shown = this.framing ? { ...clone(this.edit), crops: [], segments: [], cursorVisible: false } : this.edit;
    this.ed.setEdit(shown);
    this.version++;
  }

  private scheduleSave() {
    this.unsaved = true;
    clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => this.save(), 500);
  }

  async save() {
    clearTimeout(this.saveTimer);
    if (!this.unsaved) return;
    this.unsaved = false;
    try {
      await call("editor_save", { path: this.folder, edit: this.edit });
    } catch (e) {
      console.error("save edit", e);
    }
  }

  // MARK: undo

  /** Saves the edit as it is before a change. A burst (a drag, a slider) is
   *  one step: only the first in each 0.6 s is kept. */
  private checkpoint() {
    const now = performance.now();
    const fresh = now - this.lastCheckpoint > 600;
    this.lastCheckpoint = now;
    if (!fresh) return;
    this.undoStack.push(clone(this.edit));
    if (this.undoStack.length > 200) this.undoStack.shift();
    this.redoStack = [];
    this.canUndo = true;
    this.canRedo = false;
  }

  undo() {
    const prev = this.undoStack.pop();
    if (!prev) return;
    this.redoStack.push(clone(this.edit));
    this.lastCheckpoint = 0;
    this.apply(prev);
    this.canUndo = this.undoStack.length > 0;
    this.canRedo = true;
    this.clampSelection();
  }

  redo() {
    const next = this.redoStack.pop();
    if (!next) return;
    this.undoStack.push(clone(this.edit));
    this.lastCheckpoint = 0;
    this.apply(next);
    this.canUndo = true;
    this.canRedo = this.redoStack.length > 0;
    this.clampSelection();
  }

  private clampSelection() {
    if (this.selectedClip != null && this.selectedClip >= this.clips.length) this.selectedClip = null;
    if (this.selectedID && !this.edit.segments.some((s) => s.id === this.selectedID)) this.selectedID = null;
    if (this.selectedBlurID && !this.edit.blurs.some((b) => b.id === this.selectedBlurID)) this.selectedBlurID = null;
    if (this.time > this.duration) this.seek(this.duration);
  }

  select(id: string | null) {
    this.selectedID = id;
    if (id != null) {
      this.selectedClip = null;
      this.selectedBlurID = null;
    }
  }

  // MARK: zooms

  /** Adds a zoom at output time `t` (default: the playhead), on the footage there. */
  addZoom(t?: number) {
    const p = this.ed.locate(t ?? this.time);
    const seg = this.c.segmentInsert(p.time, this.edit.segments, this.takeDuration(p.take), p.take);
    if (!seg) return;
    this.update((e) => {
      e.segments.push(seg);
      e.segments.sort((a, b) => a.start - b.start);
    });
    this.selectedID = seg.id;
  }

  deleteSelected() {
    if (this.selectedBlurID) return this.deleteBlur(this.selectedBlurID);
    if (this.selectedID == null && this.selectedClip != null) return this.deleteClip(this.selectedClip);
    const id = this.selectedID;
    if (!id) return;
    this.update((e) => (e.segments = e.segments.filter((s) => s.id !== id)));
    this.selectedID = null;
  }

  /** Re-runs auto zoom on every take, from the clicks that are in the video. */
  reAuto() {
    this.update((e) => {
      this.takes.forEach((take, i) => {
        const clicks = take.cursor.clicks.filter((c) => this.ed.keeps(i, c.t));
        e.segments = this.c.segmentReAuto(e.segments, clicks, take.meta.duration, i);
      });
    });
  }

  setSelected(change: (s: ZoomSegment) => void) {
    const id = this.selectedID;
    if (!id) return;
    this.update((e) => {
      const s = e.segments.find((x) => x.id === id);
      if (!s) return;
      change(s);
      s.auto = false;
    });
  }

  /** Fixes the selected zoom on a point (or lets it follow the cursor with null). */
  setFocus(p: { x: number; y: number } | null) {
    this.setSelected((s) => {
      s.focusX = p ? Math.min(Math.max(p.x, 0), 1) : null;
      s.focusY = p ? Math.min(Math.max(p.y, 0), 1) : null;
    });
  }

  /** A click on the preview (shown px, top-left) -> the recording's normalised point. */
  contentPoint(px: number, py: number, w: number, h: number) {
    return this.ed.contentPoint(px, py, w, h, this.time);
  }

  cameraCentre(t: number) {
    return this.ed.cameraCentre(t);
  }

  isDragging(id: string) {
    return this.dragOrigin?.id === id;
  }

  beginDrag(id: string) {
    this.dragOrigin = clone(this.edit.segments.find((s) => s.id === id) ?? null);
    this.selectedID = id;
  }

  drag(id: string, edge: "leading" | "trailing" | null, seconds: number) {
    const o = this.dragOrigin;
    if (!o || o.id !== id) return;
    const length = this.takeDuration(o.take);
    const moved =
      edge == null
        ? this.c.segmentMove(o, seconds, length)
        : this.c.segmentResize(o, edge === "leading", edge === "leading" ? o.start + seconds : o.end + seconds, length);
    // Never let a drag push one zoom into another on the same footage.
    const others = this.edit.segments.filter((s) => s.id !== id && s.take === o.take);
    if (others.some((s) => moved.start < s.end && s.start < moved.end)) return;
    this.update((e) => {
      const i = e.segments.findIndex((s) => s.id === id);
      if (i >= 0) e.segments[i] = moved;
    });
  }

  endDrag() {
    this.dragOrigin = null;
    this.update((e) => e.segments.sort((a, b) => a.start - b.start));
  }

  // MARK: clips

  private setClips(c: Clip[]) {
    this.update((e) => {
      e.clips = c;
      e.cuts = [];
      e.trimStart = 0;
      e.trimEnd = null;
    });
  }

  selectClip(i: number | null) {
    this.selectedClip = i;
    if (i != null) {
      this.selectedID = null;
      this.selectedBlurID = null;
    }
  }

  /** Splits the clip under the playhead (S). */
  split() {
    const at = this.time;
    const next = this.c.clipSplit(this.clips, at);
    if (!next) return;
    const index = this.ed.locate(at).index;
    this.setClips(next);
    this.selectClip(index + 1);
  }

  deleteClip(i: number) {
    const next = this.c.clipDelete(this.clips, i);
    if (same(next, this.clips)) return;
    this.setClips(next);
    this.selectedClip = null;
    this.seek(Math.min(this.time, this.duration));
  }

  isDraggingClip(i: number, leading: boolean) {
    return this.clipOrigin?.index === i && this.clipOrigin.leading === leading;
  }

  beginClipDrag(i: number, leading: boolean) {
    this.clipOrigin = { index: i, leading, clips: clone(this.clips) };
    this.selectClip(i);
  }

  /** Drags clip i's edge by `seconds`; the preview follows the edge. */
  dragClip(seconds: number) {
    const o = this.clipOrigin;
    if (!o || !o.clips[o.index]) return;
    const c0 = o.clips[o.index];
    const edge = o.leading ? c0.start : c0.end;
    const next = this.c.clipResize(o.clips, o.index, o.leading, edge + seconds, this.takeDuration(c0.take));
    this.setClips(next);
    const st = this.c.clipStarts(next);
    const n = next[o.index];
    this.seek(o.leading ? st[o.index] : st[o.index] + (n.end - n.start) - 0.02);
  }

  endClipDrag() {
    this.clipOrigin = null;
  }

  beginMove(i: number) {
    this.moving = { index: i, offset: 0 };
    this.selectClip(i);
  }

  move(seconds: number) {
    if (this.moving) this.moving = { index: this.moving.index, offset: seconds };
  }

  endMove() {
    const m = this.moving;
    this.moving = null;
    const clips = this.clips;
    if (!m || !clips[m.index]) return;
    const st = this.starts;
    const c = clips[m.index];
    const centre = st[m.index] + (c.end - c.start) / 2 + m.offset;
    const to = this.c.clipDropIndex(clips, m.index, centre);
    if (to === m.index) return;
    this.setClips(this.c.clipMove(clips, m.index, to));
    this.selectClip(to);
    this.seek(this.starts[to]);
  }

  // MARK: takes and footage

  recordTake() {
    if (this.playing) this.togglePlay();
    this.save().then(() => call("record_take", { path: this.folder }));
  }

  /** A take recorded into this project finished: add its clips (pauses
   *  already left out) at the end, with auto zooms on its clicks. */
  takeRecorded(clips: Clip[]) {
    return this.takesAdded({ zooms: true, clips });
  }

  /** Takes were written into the folder (a recorded take, "Just me", an
   *  added video): reload them and add each as clips at the end. Returns
   *  the new take indices. */
  async takesAdded(opts: { zooms: boolean; clips?: Clip[] }): Promise<number[]> {
    const fresh = await call<EditorData>("editor_load", { path: this.folder });
    if (fresh.takes.length <= this.takes.length) return [];
    const added = Array.from({ length: fresh.takes.length - this.takes.length }, (_, k) => this.takes.length + k);
    this.takes = fresh.takes;
    this.ed.free();
    this.ed = new this.c.Editor(this.edit, fresh.takes);
    this.appendTakes(added, opts.zooms, added.length === 1 ? (opts.clips ?? null) : null);
    return added;
  }

  /** Add clip brought in footage (EditorModel.addFootage): `edit` when
   *  other recordings came with their clips and zooms, `videoTakes` for
   *  plain videos, which become clips at the end. */
  async footageAdded(edit: Edit | null, videoTakes: number[]) {
    const fresh = await call<EditorData>("editor_load", { path: this.folder });
    this.takes = fresh.takes;
    this.ed.free();
    this.ed = new this.c.Editor(this.edit, fresh.takes);
    if (edit) this.update((e) => Object.assign(e, edit));
    this.appendTakes(videoTakes, false);
  }

  /** New takes `indices` (already in `takes`) become clips at the end. */
  appendTakes(indices: number[], zooms: boolean, given: Clip[] | null = null) {
    if (!indices.length) {
      this.replan();
      return;
    }
    let c = this.clips;
    if (given && given.length) c = c.concat(given.map((g) => ({ start: g.start, end: g.end, take: indices[0] })));
    else c = c.concat(indices.map((i) => ({ start: 0, end: this.takeDuration(i), take: i })));
    const firstNew = this.clips.length;
    this.update((e) => {
      e.clips = c;
      e.cuts = [];
      e.trimStart = 0;
      e.trimEnd = null;
      if (zooms) {
        for (const i of indices) {
          const t = this.takes[i];
          e.segments = e.segments.concat(this.c.autoZooms(t.cursor.clicks, t.meta.duration, i));
        }
      }
    });
    this.selectClip(firstNew);
    this.seek(this.starts[Math.min(firstNew, this.clips.length - 1)]);
  }

  // MARK: hiding and cropping

  get framingTake(): number {
    void this.version;
    return this.ed.locate(this.time).take;
  }

  get hasPrivacyEdits() {
    return this.edit.blurs.length > 0 || this.edit.crops.length > 0;
  }

  openFraming(tool: FrameTool = "blur") {
    if (this.cameraPhase.kind !== "off") this.closeCamera();
    if (this.playing) this.togglePlay();
    this.frameTool = tool;
    if (this.framing) return;
    this.framing = true;
    this.selectedID = null;
    this.selectedClip = null;
    this.replan();
  }

  closeFraming() {
    if (!this.framing) return;
    this.framing = false;
    this.selectedBlurID = null;
    this.replan();
  }

  selectBlur(id: string | null) {
    this.selectedBlurID = id;
    if (id != null) {
      this.selectedID = null;
      this.selectedClip = null;
    }
  }

  /** Hides `rect` of the take at the playhead, for the whole take. */
  addBlur(rect: NormRect) {
    const style = this.selectedBlur?.style ?? this.edit.blurs.at(-1)?.style ?? "blur";
    const b: BlurRegion = { id: this.c.newId(), take: this.framingTake, rect: this.c.normRectClamped(rect), style, strength: 0.6 };
    this.update((e) => e.blurs.push(b));
    // The defaults (strength) are core's: read the box back as it parsed it.
    this.selectBlur(b.id);
  }

  setBlur(id: string, change: (b: BlurRegion) => void) {
    this.update((e) => {
      const b = e.blurs.find((x) => x.id === id);
      if (!b) return;
      change(b);
      b.rect = this.c.normRectClamped(b.rect);
    });
  }

  deleteBlur(id: string) {
    this.update((e) => (e.blurs = e.blurs.filter((b) => b.id !== id)));
    if (this.selectedBlurID === id) this.selectedBlurID = null;
  }

  setBlurEdge(start: boolean) {
    const b = this.selectedBlur;
    if (!b) return;
    const here = this.ed.locate(this.time);
    if (here.take !== b.take) return;
    this.setBlur(b.id, (r) => {
      if (start) {
        r.start = here.time;
        if (r.end != null && r.end <= here.time) r.end = null;
      } else {
        r.end = here.time;
        if (r.start != null && r.start >= here.time) r.start = null;
      }
    });
  }

  blurAlways() {
    const id = this.selectedBlurID;
    if (id) this.setBlur(id, (b) => ((b.start = null), (b.end = null)));
  }

  crop(take: number): NormRect {
    return this.edit.crops.find((c) => c.take === take)?.rect ?? { x: 0, y: 0, w: 1, h: 1 };
  }

  setCrop(rect: NormRect) {
    const take = this.framingTake;
    const next = this.c.setCrop(this.edit, rect, take);
    this.update((e) => {
      e.crops = next.crops;
    });
  }

  resetCrop() {
    this.setCrop({ x: 0, y: 0, w: 1, h: 1 });
  }

  /** Where the take at the playhead sits in a preview of `shown` size. */
  takeRect(shownW: number): Rect {
    const k = shownW / Math.max(this.canvas.width, 1);
    const f = this.editor.frameRect(this.framingTake);
    return { x: f.x * k, y: f.y * k, w: f.w * k, h: f.h * k };
  }

  // MARK: backdrop

  async setBackdropImage(path: string, name?: string) {
    if (name && this.edit.backdropImage === name) {
      this.update((e) => (e.backdrop = "image"));
      return;
    }
    try {
      const copied = await call<string>("backdrop_copy", { folder: this.folder, from: path, name: name ?? null });
      const old = this.edit.backdropImage;
      this.update((e) => {
        e.backdrop = "image";
        e.backdropImage = copied;
      });
      if (old && old !== copied) call("recording_remove_file", { folder: this.folder, name: old });
    } catch (e) {
      console.error("backdrop", e);
    }
  }

  // MARK: music

  openMusic() {
    if (this.playing) this.togglePlay();
    this.showingMusic = true;
  }

  closeMusic() {
    this.showingMusic = false;
  }

  setMusic(change: (m: MusicChoice) => void) {
    this.update((e) => {
      if (!e.music) return;
      change(e.music);
    });
  }

  beginMusicDrag() {
    this.musicOrigin = this.edit.music?.offset ?? null;
  }
  beginMusicDragIfNeeded() {
    if (this.musicOrigin == null) this.beginMusicDrag();
  }

  /** `free` (Alt held) leaves the grid alone. */
  dragMusic(seconds: number, free = false) {
    const o = this.musicOrigin;
    const m = this.edit.music;
    if (o == null || !m) return;
    const room = Math.max(0, m.track.duration - this.duration);
    let want = Math.min(Math.max(0, o + seconds), room);
    if (!free && this.musicGrid) want = this.snapMusic(want, this.musicGrid, room);
    this.setMusic((x) => (x.offset = want));
  }

  endMusicDrag() {
    this.musicOrigin = null;
  }

  /** A lift landing on a zoom wins when near; otherwise the nearest bar line. */
  private snapMusic(want: number, g: { bar: number; lifts: number[] }, room: number) {
    let best: number | null = null;
    let nearest = Math.max(0.6, g.bar * 0.6);
    for (const lift of g.lifts) {
      for (const z of this.zoomMoments) {
        const at = lift - z;
        if (at >= 0 && at <= room && Math.abs(at - want) < nearest) {
          best = at;
          nearest = Math.abs(at - want);
        }
      }
    }
    if (best != null) return best;
    const line = this.c.nearestBarLine(g, want);
    return line <= room ? line : Math.max(0, line - g.bar);
  }

  /** The lift and the zoom that meet at the current offset, if any. */
  get musicLanding(): { lift: number; zoom: number } | null {
    const m = this.edit.music, g = this.musicGrid;
    if (!m || !g) return null;
    for (const lift of g.lifts) for (const z of this.zoomMoments) if (Math.abs(lift - m.offset - z) < 0.05) return { lift, zoom: z };
    return null;
  }

  // MARK: camera (recording yourself)

  get hasCamera() {
    return this.edit.cameraClips.length > 0 || this.takes.some((t) => t.meta.camera != null);
  }

  setCameraClip(id: string, change: (c: CameraClip) => void) {
    this.update((e) => {
      const c = e.cameraClips.find((x) => x.id === id);
      if (c) change(c);
    });
  }

  deleteCameraClip(id: string) {
    this.update((e) => (e.cameraClips = e.cameraClips.filter((c) => c.id !== id)));
  }

  // Recording yourself: ms-capture's camera/flow.ts.
  openCamera() {
    cameraFlow.openCamera(this);
  }
  closeCamera() {
    cameraFlow.closeCamera(this);
  }
  toggleCameraRecording() {
    cameraFlow.toggleCameraRecording(this);
  }

  private arts = new Map<string, CursorArt | null>();

  /** core-wasm's cursor sprite, once per look (the painter and the tiles share it). */
  cursorArt(style: string, tint: string, label: string, artHeight: number): CursorArt | null {
    const key = `${style}/${tint}/${label}/${artHeight}`;
    if (!this.arts.has(key)) {
      let art: CursorArt | null = null;
      try {
        art = this.c.cursorArt(style, tint, label, artHeight);
      } catch (e) {
        console.error("cursorArt", e);
      }
      if (this.arts.size > 64) this.arts.clear();
      this.arts.set(key, art);
    }
    return this.arts.get(key)!;
  }

  close() {
    if (this.cameraPhase.kind !== "off") this.closeCamera();
    this.playing = false;
    this.save();
  }
}
