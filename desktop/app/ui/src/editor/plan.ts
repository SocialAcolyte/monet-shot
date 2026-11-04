// The FramePlan (docs/porting/contracts/frame-plan.md): what to draw for
// output time t. Canvas pixels, top-left origin; colours sRGB, straight alpha.

export type Rect = { x: number; y: number; w: number; h: number };
export type Point = { x: number; y: number };
export type Rgba = { r: number; g: number; b: number; a: number };

export interface FramePlan {
  t: number;
  canvas: { width: number; height: number };
  clipIndex: number;
  take: number;
  takeTime: number;
  backdrop: BackdropPlan;
  shadow: ShadowPlan | null;
  frame: Rect;
  cornerRadius: number;
  source: SourcePlan;
  camera: { scale: number; centerX: number; centerY: number };
  ripples: RipplePlan[];
  cursor: CursorPlan | null;
  webcam: WebcamPlan[];
  /** A clip fading: the backdrop again over everything at this opacity. */
  veil: number;
  /** The clip's playback speed: the take's video plays at this rate. */
  speed: number;
  /** Words over everything (the veil too), in drawing order. */
  texts: TextPlan[];
}

/** One text: textArt(plan) drawn centred on `center`, scaled by `scale`
 *  about its centre, at `opacity`. */
export interface TextPlan {
  lines: string[];
  px: number;
  tracking: number;
  center: Point;
  opacity: number;
  scale: number;
  /** One alpha per word, reading order; empty = all shown. */
  words: number[];
  color: Rgba;
  backing: Rgba | null;
  shadow: boolean;
}

/** textArt(text) from core-wasm. */
export interface TextArt {
  width: number;
  height: number;
  /** Premultiplied RGBA8, sRGB. */
  rgba: Uint8Array;
}

export type BackdropPlan =
  | { kind: "solid"; color: Rgba; grain: number }
  | { kind: "linear"; from: Point; to: Point; colorFrom: Rgba; colorTo: Rgba; grain: number }
  | { kind: "image"; file: string; blurSigma: number; fallback: BackdropPlan };

export interface ShadowPlan {
  rect: Rect;
  radius: number;
  color: Rgba;
  sigma: number;
}

export interface SourcePlan {
  take: number;
  width: number;
  height: number;
  hides: HidePlan[];
  bounds: Rect;
  rect: Rect;
  lanczos: boolean;
}

export interface HidePlan {
  style: "blur" | "pixelate" | "solid";
  rect: Rect;
  sigma: number;
  cell: number;
  color: Rgba;
}

export interface CursorPlan {
  style: "classic" | "white" | "soft" | "dot" | "tag";
  tint: "clay" | "sky" | "mint" | "butter" | "lilac" | "rose";
  label: string;
  artHeight: number;
  tip: Point;
  height: number;
}

export interface RipplePlan {
  center: Point;
  radius: number;
  alpha: number;
  color: Rgba;
}

export interface WebcamPlan {
  kind: "overlay" | "take";
  file: string;
  time: number;
  full: boolean;
  opacity: number;
  mirror: boolean;
  rect: Rect;
  radius: number;
  rim: { rect: Rect; radius: number; color: Rgba } | null;
  shadow: ShadowPlan | null;
}

/** cursorArt(style, tint, label, artHeight) from core-wasm. */
export interface CursorArt {
  width: number;
  height: number;
  tipX: number;
  tipY: number;
  /** Premultiplied RGBA8, sRGB. */
  rgba: Uint8Array;
}
