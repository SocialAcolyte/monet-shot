// core-wasm (monetshot-core in the webview): every decision the Mac's Kit
// makes, so the preview and the export plan the same frame and the timeline
// edits behave as on the Mac. Nothing here re-implements Kit logic.
//
// The package is built by ms-core into desktop/crates/core-wasm/pkg
// (aliased as "monetshot-core-wasm" in vite.config.ts).
import type { CursorArt, FramePlan, Rect, TextArt, TextPlan } from "./plan";

export interface Clip {
  start: number;
  end: number;
  take: number;
  /** Playback speed (1 when absent): 2 is twice as fast. */
  speed?: number;
  /** Output seconds the clip fades up from / down to the backdrop. */
  fadeIn?: number;
  fadeOut?: number;
  [k: string]: unknown;
}

/** The speeds the editor offers, as Clip.speeds on the Mac. */
export const SPEEDS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4];
/** A clip's speed as used (Clip.rate). */
export const rate = (c: Clip) => {
  const s = c.speed ?? 1;
  return Number.isFinite(s) ? Math.min(4, Math.max(0.25, s)) : 1;
};
/** How long a clip lasts in the video (Clip.outputDuration). */
export const outputDuration = (c: Clip) => (c.end - c.start) / rate(c);
/** "2×", "0.5×". */
export const speedLabel = (r: number) => `${Number.isInteger(r) ? r : +r.toFixed(2)}×`;

export interface ZoomSegment {
  id: string;
  start: number;
  end: number;
  scale: number;
  take: number;
  auto: boolean;
  focusX?: number | null;
  focusY?: number | null;
  [k: string]: unknown;
}

export interface NormRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface BlurRegion {
  id: string;
  take: number;
  rect: NormRect;
  style: "blur" | "pixelate" | "solid";
  strength: number;
  start?: number | null;
  end?: number | null;
  [k: string]: unknown;
}

export interface CameraClip {
  id: string;
  file: string;
  at: number;
  duration: number;
  full?: boolean;
  [k: string]: unknown;
}

export interface Song {
  id: string;
  title: string;
  artist: string;
  duration: number;
  [k: string]: unknown;
}

export interface MusicChoice {
  track: Song;
  file: string;
  offset: number;
  volume: number;
  fadeIn: boolean;
  fadeOut: boolean;
  [k: string]: unknown;
}

/** Words on the video (TextOverlay): output time; x/y the centre, 0...1. */
export interface TextOverlay {
  id: string;
  text: string;
  at: number;
  duration: number;
  style: "title" | "caption" | "label";
  animation: "fade" | "rise" | "pop" | "words";
  x: number;
  y: number;
  size: number;
  tone: "light" | "dark" | "clay";
  /** A box behind the words; absent = the style's choice (all but titles). */
  backing?: boolean | null;
  uppercase: boolean;
  [k: string]: unknown;
}

export const TEXT_STYLES = [
  { value: "title", label: "Title" },
  { value: "caption", label: "Caption" },
  { value: "label", label: "Label" },
] as const;
export const TEXT_ANIMATIONS = [
  { value: "fade", label: "Fade" },
  { value: "rise", label: "Rise" },
  { value: "pop", label: "Pop" },
  { value: "words", label: "Word by word" },
] as const;
export const TEXT_TONES = [
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
  { value: "clay", label: "Clay" },
] as const;
/** TextOverlay.hasBacking */
export const hasBacking = (o: TextOverlay) => o.backing ?? o.style !== "title";

/** A format (EditFormat): a pace and a look in one go. */
export interface Format {
  id: string;
  name: string;
  blurb: string;
  speed: number;
  clipFade: number;
  openFade: number;
  closeFade: number;
  zoomScale: number;
  padding: number;
  cornerRadius: number;
  cursorSmoothing: number;
  uppercaseTitles: boolean;
  musicMood: string;
}

/** edit.json, as core reads it (defaults filled in; unknown keys kept). */
export interface Edit {
  clips?: Clip[] | null;
  /** Absent until the first text is added. */
  texts?: TextOverlay[] | null;
  /** The format last applied (Format.id). */
  format?: string | null;
  /** What was said, shown as captions (absent until switched). */
  captions?: boolean | null;
  segments: ZoomSegment[];
  blurs: BlurRegion[];
  crops: { take: number; rect: NormRect; [k: string]: unknown }[];
  cameraClips: CameraClip[];
  cameraLook: {
    visible: boolean;
    shape: string;
    corner: string;
    size: number;
    mirror: boolean;
    duckMusic: boolean;
    [k: string]: unknown;
  };
  music?: MusicChoice | null;
  backdrop: string;
  backdropImage?: string | null;
  backdropBlur: number;
  padding: number;
  cornerRadius: number;
  shadow: boolean;
  cursorVisible: boolean;
  cursorStyle: string;
  cursorTint: string;
  cursorLabel: string;
  cursorScale: number;
  cursorSmoothing: number;
  clickRipple: boolean;
  outputWidth: number;
  canvasAspect: number;
  cuts: unknown[];
  trimStart: number;
  trimEnd?: number | null;
  [k: string]: unknown;
}

export interface Located {
  index: number;
  take: number;
  time: number;
}

export interface Span {
  take: number;
  start: number;
  end: number;
  at: number;
  speed: number;
  fadeIn: number;
  fadeOut: number;
}

export interface Viewport {
  x: number;
  y: number;
  w: number;
  h: number;
  scale: number;
  centerX: number;
  centerY: number;
}

export interface Editor {
  setEdit(edit: Edit): void;
  edit(): Edit;
  duration(): number;
  plan(t: number): FramePlan;
  canvasSize(): { width: number; height: number };
  clips(): Clip[];
  starts(): number[];
  spans(): Span[];
  locate(t: number): Located;
  output(take: number, time: number): number | undefined;
  keeps(take: number, time: number): boolean;
  frameRect(take: number): Rect;
  viewport(take: number, time: number): Viewport;
  crop(take: number): NormRect;
  contentPoint(px: number, py: number, w: number, h: number, t: number): { x: number; y: number } | null;
  cameraCentre(t: number): { x: number; y: number };
  bubbleRect(): Rect;
  /** Take `take`'s transcript changed: re-plans (captions). */
  setTranscript(take: number, transcript: Transcript | null): void;
  /** Every transcribed word the edit shows, output time, play order. */
  captionWords(): CaptionWord[];
  transcriptText(): string;
  srt(): string;
  free(): void;
}

/** transcript.json: what was said in a take, in its own time. */
export interface Transcript {
  words: { text: string; start: number; end: number }[];
  language?: string | null;
  engine?: string | null;
  [k: string]: unknown;
}

/** A transcript word placed in the video. */
export interface CaptionWord {
  text: string;
  start: number;
  end: number;
  span: number;
  take: number;
  index: number;
}

export interface Core {
  Editor: new (edit: Edit, takes: { meta: unknown; cursor: unknown; dir: string }[]) => Editor;
  cursorArt(style: string, tint: string, label: string, artHeight: number): CursorArt;
  textArt(text: TextPlan): TextArt;
  clipStarts(clips: Clip[]): number[];
  clipSplit(clips: Clip[], atOutput: number): Clip[] | null;
  clipDelete(clips: Clip[], i: number): Clip[];
  clipResize(clips: Clip[], i: number, leading: boolean, to: number, takeDuration: number): Clip[];
  clipMove(clips: Clip[], from: number, to: number): Clip[];
  clipDropIndex(clips: Clip[], dragging: number, centreAt: number): number;
  clipSetSpeed(clips: Clip[], i: number, speed: number): Clip[];
  formats(): Format[];
  formatApply(edit: Edit, id: string, duration: number): Edit | null;
  formatStyled(id: string, text: TextOverlay): TextOverlay;
  textInsert(text: string, style: string, animation: string, at: number, videoLength: number, duration?: number): TextOverlay;
  textMove(text: TextOverlay, at: number, videoLength: number): TextOverlay;
  textResize(text: TextOverlay, leading: boolean, to: number, videoLength: number): TextOverlay;
  autoZooms(clicks: unknown[], duration: number, take: number, scale?: number): ZoomSegment[];
  segmentInsert(at: number, segments: ZoomSegment[], duration: number, take: number, length?: number): ZoomSegment | null;
  segmentMove(segment: ZoomSegment, delta: number, duration: number): ZoomSegment;
  segmentResize(segment: ZoomSegment, leading: boolean, to: number, duration: number): ZoomSegment;
  segmentReAuto(segments: ZoomSegment[], clicks: unknown[], duration: number, take: number): ZoomSegment[];
  cameraInsert(clip: CameraClip, clips: CameraClip[]): CameraClip[];
  normRectClamped(rect: NormRect, minSize?: number): NormRect;
  normRectMoved(rect: NormRect, dx: number, dy: number): NormRect;
  normRectResized(rect: NormRect, hx: number, hy: number, dx: number, dy: number, minSize?: number): NormRect;
  normRectSpanning(ax: number, ay: number, bx: number, by: number): NormRect;
  setCrop(edit: Edit, rect: NormRect, take: number): Edit;
  canvasSize(edit: Edit, recordingAspect: number): { width: number; height: number };
  nearestBarLine(grid: unknown, t: number): number;
  musicGain(t: number, length: number, fadeIn: boolean, fadeOut: boolean, voice: unknown): number;
  newId(): string;
  transcriptEdit(transcript: Transcript, i: number, text: string): Transcript;
}

let loaded: Promise<Core> | null = null;

export function core(): Promise<Core> {
  loaded ??= (async () => {
    const m = await import("monetshot-core-wasm");
    await m.default();
    return m as unknown as Core;
  })();
  return loaded;
}
