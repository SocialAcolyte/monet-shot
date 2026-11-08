// The preview's painter: draws a FramePlan with WebGL2, the same picture the
// export's tiny-skia painter draws from the same plan. It only draws what
// the plan says, in the contract's order:
//   backdrop (cached) > shadow > content [frame, hides, ripples, cursor]
//   clipped to the rounded frame > webcam.
//
// Colour: like CoreImage, everything is composited in linear light. The
// work buffer is an SRGB8_ALPHA8 texture, so blending happens on linear
// values and storage stays 8-bit. Pictures CoreImage only transforms (the
// source unless shrunk with Lanczos, the webcam, the painting) are filtered
// on their gamma values and decoded after, as CoreImage does
// (frame-plan.md, "Coordinates and colour"). The last pass encodes to the
// (non-sRGB) canvas.
//
// The canvas is drawn at its on-screen size, not the plan's: every plan
// coordinate (and blur sigma) is scaled by k = drawn / canvas.

import type { BackdropPlan, CursorArt, FramePlan, HidePlan, Rect, Rgba, ShadowPlan, TextArt, TextPlan, WebcamPlan } from "./plan";

export interface Sources {
  /** The take's video, with a decoded frame at the plan's takeTime. */
  video(take: number): TexImageSource | null;
  /** A webcam file's video, or null if it has no frame at `time` yet. */
  webcam(file: string, time: number): TexImageSource | null;
  /** A picture in the recording (backdrop), or null while it loads / if it can't. */
  image(file: string): HTMLImageElement | ImageBitmap | null | "failed";
  cursorArt(style: string, tint: string, label: string, artHeight: number): CursorArt | null;
  /** core-wasm's picture of a text (the export's own). */
  textArt(text: TextPlan): TextArt | null;
}

// MARK: shaders

const VERT = `#version 300 es
in vec2 aCorner;
uniform vec4 uRect;      // where the quad goes, in target px (top-left origin)
uniform vec2 uTarget;    // target size px
out vec2 vPos;           // this fragment in target px (top-left origin)
void main() {
  vec2 p = uRect.xy + aCorner * uRect.zw;
  vPos = p;
  gl_Position = vec4(p.x / uTarget.x * 2.0 - 1.0, 1.0 - p.y / uTarget.y * 2.0, 0.0, 1.0);
}`;

const COMMON = `#version 300 es
precision highp float;
in vec2 vPos;
out vec4 outColor;
uniform vec2 uTarget;

float srgbToLinear(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
vec3 srgbToLinear(vec3 c) { return vec3(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b)); }
float linearToSrgb(float c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055; }
vec3 linearToSrgb(vec3 c) { return vec3(linearToSrgb(c.r), linearToSrgb(c.g), linearToSrgb(c.b)); }

// Samples a picture: an 8-bit gamma texture (plain bilinear, as CoreImage
// transforms an image) is decoded after filtering; an sRGB texture (the
// Lanczos shrink) already filtered in linear. Out: linear, premultiplied.
vec4 pick(sampler2D t, vec2 uv, float gamma) {
  vec4 c = texture(t, uv);
  return gamma > 0.5 ? vec4(srgbToLinear(c.rgb) * c.a, c.a) : c;
}
vec4 pickLod(sampler2D t, vec2 uv, float gamma) {
  vec4 c = textureLod(t, uv, 0.0);
  return gamma > 0.5 ? vec4(srgbToLinear(c.rgb) * c.a, c.a) : c;
}

// Coverage of a rounded rect (x, y, w, h) with corner r, 1 px antialiasing.
float rrect(vec2 p, vec4 rc, float r) {
  vec2 h = rc.zw * 0.5;
  r = min(r, min(h.x, h.y));
  vec2 q = abs(p - (rc.xy + h)) - h + r;
  float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
  return clamp(0.5 - d, 0.0, 1.0);
}

// A gaussian-blurred rounded rect (Evan Wallace's closed form along x,
// sampled along y): the shadow under the frame and the camera bubble.
vec2 erf2(vec2 x) {
  vec2 s = sign(x), a = abs(x);
  x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
  x *= x;
  return s - s / (x * x);
}
float gauss(float x, float sigma) { return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066283 * sigma); }
float shadowX(float x, float y, float sigma, float corner, vec2 halfSize) {
  float delta = min(halfSize.y - corner - abs(y), 0.0);
  float curved = halfSize.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
  vec2 integral = 0.5 + 0.5 * erf2((x + vec2(-curved, curved)) * (0.70710678 / sigma));
  return integral.y - integral.x;
}
float blurredRRect(vec2 p, vec4 rc, float corner, float sigma) {
  if (sigma < 0.01) return rrect(p, rc, corner);
  vec2 halfSize = rc.zw * 0.5;
  corner = min(corner, min(halfSize.x, halfSize.y));
  p -= rc.xy + halfSize;
  float low = p.y - halfSize.y, high = p.y + halfSize.y;
  float start = clamp(-3.0 * sigma, low, high), end = clamp(3.0 * sigma, low, high);
  float step = (end - start) / 6.0, y = start + step * 0.5, v = 0.0;
  for (int i = 0; i < 6; i++) {
    v += shadowX(p.x, p.y - y, sigma, corner, halfSize) * gauss(y, sigma) * step;
    y += step;
  }
  return v;
}
`;

const FILL = `${COMMON}
uniform vec4 uColor;      // linear, premultiplied
void main() { outColor = uColor; }`;

/** A colour clipped to the rounded frame. */
const FRAME_FILL = `${COMMON}
uniform vec4 uFrame;
uniform float uRadius;
uniform vec4 uColor;
void main() { outColor = uColor * rrect(vPos, uFrame, uRadius); }`;

/** A linear gradient, projected onto from→to and clamped (backdrop). */
const GRADIENT = `${COMMON}
uniform vec2 uFrom, uTo;
uniform vec4 uA, uB;      // linear, premultiplied
void main() {
  vec2 d = uTo - uFrom;
  float t = clamp(dot(vPos - uFrom, d) / max(dot(d, d), 1e-6), 0.0, 1.0);
  outColor = mix(uA, uB, t);
}`;

/** Draws a texture into a rect (cover-fit done by the caller via uSrc). */
const IMAGE = `${COMMON}
uniform sampler2D uTex;   // the picture, 8-bit gamma (decoded after filtering)
uniform vec4 uDst;        // where, target px
uniform vec4 uSrc;        // which part of the texture, 0..1 (top-left origin)
uniform float uFlipY;     // 1 when the texture is GL-oriented (an FBO)
void main() {
  vec2 f = (vPos - uDst.xy) / uDst.zw;
  vec2 uv = uSrc.xy + f * uSrc.zw;
  if (uFlipY > 0.5) uv.y = 1.0 - uv.y;
  outColor = pick(uTex, uv, 1.0);
}`;

/** One direction of a separable gaussian; CLAMP_TO_EDGE extends edges. */
const BLUR = `${COMMON}
uniform sampler2D uTex;   // same size as the target, GL-oriented
uniform vec2 uDir;        // one px along x or y
uniform float uSigma;
void main() {
  vec2 uv = gl_FragCoord.xy / uTarget;
  if (uSigma < 0.3) { outColor = texture(uTex, uv); return; }
  int r = int(min(ceil(uSigma * 3.0), 60.0));
  vec4 sum = vec4(0.0);
  float wsum = 0.0;
  for (int i = -60; i <= 60; i++) {
    if (i < -r || i > r) continue;
    float w = exp(-float(i * i) / (2.0 * uSigma * uSigma));
    sum += texture(uTex, uv + uDir * float(i) / uTarget) * w;
    wsum += w;
  }
  outColor = sum / wsum;
}`;

/** The backdrop, from its cached texture, with its still grain. */
const BACKDROP = `${COMMON}
uniform sampler2D uTex;   // GL-oriented, any size (bilinear up)
uniform float uGrain;
uniform float uOpacity;   // 1 underneath; a fading clip's veil draws it again over everything
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void main() {
  vec4 c = texture(uTex, vec2(vPos.x / uTarget.x, 1.0 - vPos.y / uTarget.y));
  if (uGrain > 0.0) c.rgb *= (1.0 - uGrain) + uGrain * hash(floor(vPos));
  outColor = c * uOpacity;
}`;

const SHADOW = `${COMMON}
uniform vec4 uRc;
uniform float uRadius, uSigma;
uniform vec4 uColor;      // linear premultiplied
void main() { outColor = uColor * blurredRRect(vPos, uRc, uRadius, uSigma); }`;

/** The recording: source.rect stretched onto the frame, clamped to bounds,
 *  clipped to the rounded frame. */
const CONTENT = `${COMMON}
uniform sampler2D uTex;   // the take's frame, top-left origin rows
uniform float uGamma;     // 1: 8-bit gamma texture (bilinear); 0: sRGB + mipmaps (Lanczos shrink)
uniform vec2 uSize;       // source px
uniform vec4 uFrame, uSrcRect, uBounds;
uniform float uRadius;
void main() {
  float m = rrect(vPos, uFrame, uRadius);
  if (m <= 0.0) discard;
  vec2 s = uSrcRect.xy + (vPos - uFrame.xy) / uFrame.zw * uSrcRect.zw;
  s = clamp(s, uBounds.xy + 0.5, uBounds.xy + uBounds.zw - 0.5);
  outColor = pick(uTex, s / uSize, uGamma) * m;
}`;

/** The Lanczos shrink (CILanczosScaleTransform), in linear light, as two
 *  separable Lanczos-3 passes. H: source rows -> frame-width columns. */
const LANCZOS = `
float sinc(float x) { x *= 3.14159265; return abs(x) < 1e-4 ? 1.0 : sin(x) / x; }
float lanczos3(float x) { return abs(x) < 3.0 ? sinc(x) * sinc(x / 3.0) : 0.0; }
`;
const LANCZOS_H = `${COMMON}${LANCZOS}
uniform sampler2D uTex;   // the take, sRGB (texelFetch: linear values)
uniform float uSrcX, uSrcW, uOutW;
uniform int uRow0;
uniform vec4 uBounds;     // source px
void main() {
  float scale = max(1.0, uSrcW / uOutW);
  float sx = uSrcX + (gl_FragCoord.x) / uOutW * uSrcW;
  int row = clamp(uRow0 + int(gl_FragCoord.y), int(uBounds.y), int(uBounds.y + uBounds.w) - 1);
  int i0 = int(floor(sx - 3.0 * scale)), i1 = int(ceil(sx + 3.0 * scale));
  int bx0 = int(uBounds.x), bx1 = int(uBounds.x + uBounds.z) - 1;
  vec4 sum = vec4(0.0);
  float ws = 0.0;
  for (int t = 0; t < 96; t++) {
    int i = i0 + t;
    if (i > i1) break;
    float w = lanczos3((float(i) + 0.5 - sx) / scale);
    sum += texelFetch(uTex, ivec2(clamp(i, bx0, bx1), row), 0) * w;
    ws += w;
  }
  outColor = sum / ws;
}`;
/** V: the H pass's columns -> the frame, clipped to its rounded corners. */
const LANCZOS_V = `${COMMON}${LANCZOS}
uniform sampler2D uTex;   // the H pass (linear)
uniform vec4 uFrame;
uniform float uRadius;
uniform float uSrcY, uSrcH;
uniform int uRow0, uRows;
void main() {
  float m = rrect(vPos, uFrame, uRadius);
  if (m <= 0.0) discard;
  // uFrame.w is the frame's height (x, y, width, height).
  float scale = max(1.0, uSrcH / uFrame.w);
  int col = clamp(int(floor(vPos.x - uFrame.x)), 0, textureSize(uTex, 0).x - 1);
  float sy = uSrcY + (vPos.y - uFrame.y) / uFrame.w * uSrcH;
  int j0 = int(floor(sy - 3.0 * scale)), j1 = int(ceil(sy + 3.0 * scale));
  vec4 sum = vec4(0.0);
  float ws = 0.0;
  for (int t = 0; t < 96; t++) {
    int j = j0 + t;
    if (j > j1) break;
    float w = lanczos3((float(j) + 0.5 - sy) / scale);
    sum += texelFetch(uTex, ivec2(col, clamp(j - uRow0, 0, uRows - 1)), 0) * w;
    ws += w;
  }
  outColor = clamp(sum / ws, 0.0, 1.0) * m;
}`;

/** A hide, drawn over the framed output, clipped to the rounded frame.
 *  mode 0 solid, 1 pixelate (sample the video at cell centres),
 *  2 blur (a pre-blurred texture of the hide's area). */
const HIDE = `${COMMON}
uniform int uMode;
uniform vec4 uFrame, uSrcRect;   // to map output px <-> source px
uniform float uRadius;
uniform vec4 uHide;              // source px
uniform float uCell;
uniform vec4 uColor;
uniform sampler2D uTex;          // the video (pixelate) or blurred area (blur)
uniform vec2 uSize;              // video size px
uniform float uGamma;            // the video texture's kind (see CONTENT)
uniform vec4 uOut;               // the hide on the output, px (blur texture's extent)
void main() {
  float m = rrect(vPos, uFrame, uRadius);
  if (m <= 0.0) discard;
  vec2 s = uSrcRect.xy + (vPos - uFrame.xy) / uFrame.zw * uSrcRect.zw;
  if (s.x < uHide.x || s.y < uHide.y || s.x > uHide.x + uHide.z || s.y > uHide.y + uHide.w) discard;
  vec4 c;
  if (uMode == 0) {
    c = uColor;
  } else if (uMode == 1) {
    vec2 cell = floor((s - uHide.xy) / uCell);
    vec2 centre = clamp(uHide.xy + (cell + 0.5) * uCell, uHide.xy, uHide.xy + uHide.zw - 0.5);
    c = pickLod(uTex, (floor(centre) + 0.5) / uSize, uGamma);
  } else {
    vec2 f = (vPos - uOut.xy) / uOut.zw;
    c = texture(uTex, vec2(f.x, 1.0 - f.y));
  }
  outColor = c * m;
}`;

/** A hide's area of the source, edges extended, at output resolution (the
 *  input to the blur passes). Target = the area's own texture. */
const HIDE_GRAB = `${COMMON}
uniform sampler2D uTex;
uniform vec2 uSize;
uniform vec4 uOut;               // the area on the output, px
uniform vec4 uFrame, uSrcRect;
uniform vec4 uHide;              // source px
uniform float uGamma;
void main() {
  vec2 o = uOut.xy + vPos / uTarget * uOut.zw;
  vec2 s = uSrcRect.xy + (o - uFrame.xy) / uFrame.zw * uSrcRect.zw;
  s = clamp(s, uHide.xy + 0.5, uHide.xy + uHide.zw - 0.5);
  outColor = pick(uTex, s / uSize, uGamma);
}`;

/** A click ripple: a ring, 0 inside 0.55r, up to 1 at 0.78r, 0 at r. */
const RIPPLE = `${COMMON}
uniform vec2 uCentre;
uniform float uR, uAlpha;
uniform vec4 uColor;      // linear premultiplied
uniform vec4 uFrame;
uniform float uRadius;
void main() {
  float d = distance(vPos, uCentre);
  float p = d <= 0.55 * uR ? 0.0 : d < 0.78 * uR ? (d - 0.55 * uR) / (0.23 * uR) : d < uR ? (uR - d) / (0.22 * uR) : 0.0;
  outColor = uColor * (uAlpha * p * rrect(vPos, uFrame, uRadius));
}`;

/** The cursor sprite: premultiplied sRGB in, premultiplied linear out. */
const SPRITE = `${COMMON}
uniform sampler2D uTex;
uniform vec4 uDst;
uniform vec4 uFrame;
uniform float uRadius;
void main() {
  vec2 f = (vPos - uDst.xy) / uDst.zw;
  vec4 c = texture(uTex, f);
  vec3 rgb = c.a > 0.0 ? srgbToLinear(c.rgb / c.a) * c.a : vec3(0.0);
  outColor = vec4(rgb, c.a) * rrect(vPos, uFrame, uRadius);
}`;

/** A text's picture (premultiplied sRGB), faded by uOpacity. */
const TEXT = `${COMMON}
uniform sampler2D uTex;
uniform vec4 uDst;
uniform float uOpacity;
void main() {
  vec4 c = texture(uTex, (vPos - uDst.xy) / uDst.zw);
  vec3 rgb = c.a > 0.0 ? srgbToLinear(c.rgb / c.a) * c.a : vec3(0.0);
  outColor = vec4(rgb, c.a) * uOpacity;
}`;

/** The camera as one group: shadow under rim under face, then opacity. */
const WEBCAM = `${COMMON}
uniform sampler2D uTex;          // camera frame, 8-bit gamma (bilinear, decoded after)
uniform vec2 uSize;              // camera px
uniform vec4 uFace;
uniform float uRadius, uMirror, uOpacity;
uniform vec4 uRim; uniform float uRimRadius; uniform vec4 uRimColor; uniform float uHasRim;
uniform vec4 uShRect; uniform float uShRadius, uShSigma; uniform vec4 uShColor; uniform float uHasShadow;
void main() {
  vec4 c = vec4(0.0);
  if (uHasShadow > 0.5) c = uShColor * blurredRRect(vPos, uShRect, uShRadius, uShSigma);
  if (uHasRim > 0.5) { vec4 r = uRimColor * rrect(vPos, uRim, uRimRadius); c = r + c * (1.0 - r.a); }
  float m = rrect(vPos, uFace, uRadius);
  if (m > 0.0) {
    // Cover-fit the camera picture into the rect.
    float k = max(uFace.z / uSize.x, uFace.w / uSize.y);
    vec2 shown = uSize * k;
    vec2 off = (uFace.zw - shown) * 0.5;
    vec2 f = (vPos - uFace.xy - off) / shown;
    if (uMirror > 0.5) f.x = 1.0 - f.x;
    vec4 face = pick(uTex, clamp(f, 0.0, 1.0), 1.0) * m;
    c = face + c * (1.0 - face.a);
  }
  outColor = c * uOpacity;
}`;

/** Last pass: the linear work buffer, encoded for the canvas. */
const PRESENT = `${COMMON}
uniform sampler2D uTex;
void main() {
  vec4 c = texture(uTex, gl_FragCoord.xy / uTarget);
  outColor = vec4(linearToSrgb(c.a > 0.0 ? c.rgb / c.a : vec3(0.0)), 1.0);
}`;

// MARK: GL plumbing

type Prog = { p: WebGLProgram; u: Map<string, WebGLUniformLocation | null> };

interface Target {
  fb: WebGLFramebuffer;
  tex: WebGLTexture;
  w: number;
  h: number;
}

function lin(c: number) {
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

/** sRGB straight alpha -> linear premultiplied. */
function premul(c: Rgba): [number, number, number, number] {
  return [lin(c.r) * c.a, lin(c.g) * c.a, lin(c.b) * c.a, c.a];
}

export class Painter {
  private gl: WebGL2RenderingContext;
  private progs = new Map<string, Prog>();
  private quad: WebGLVertexArrayObject;
  private work: Target | null = null;
  private tmp: Target[] = [];
  private videoTex = new Map<string, { tex: WebGLTexture; w: number; h: number; gamma: boolean }>();
  private imageTex = new Map<string, { tex: WebGLTexture; w: number; h: number }>();
  private cursorTex = new Map<string, { tex: WebGLTexture; art: CursorArt }>();
  private textTex = new Map<string, { tex: WebGLTexture; art: TextArt }>();
  private backdrop: { key: string; t: Target } | null = null;
  /** Drawn px per canvas px. */
  private k = 1;
  private size = { w: 1, h: 1 };

  constructor(private canvas: HTMLCanvasElement) {
    const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, premultipliedAlpha: true, preserveDrawingBuffer: true });
    if (!gl) throw new Error("WebGL2 is not available");
    this.gl = gl;
    const vao = gl.createVertexArray()!;
    gl.bindVertexArray(vao);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    this.quad = vao;
    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
  }

  private prog(name: string, src: string): Prog {
    const hit = this.progs.get(name);
    if (hit) return hit;
    const gl = this.gl;
    const sh = (type: number, s: string) => {
      const o = gl.createShader(type)!;
      gl.shaderSource(o, s);
      gl.compileShader(o);
      if (!gl.getShaderParameter(o, gl.COMPILE_STATUS)) throw new Error(`${name}: ${gl.getShaderInfoLog(o)}`);
      return o;
    };
    const p = gl.createProgram()!;
    gl.attachShader(p, sh(gl.VERTEX_SHADER, VERT));
    gl.attachShader(p, sh(gl.FRAGMENT_SHADER, src));
    gl.bindAttribLocation(p, 0, "aCorner");
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(`${name}: ${gl.getProgramInfoLog(p)}`);
    const out = { p, u: new Map<string, WebGLUniformLocation | null>() };
    this.progs.set(name, out);
    return out;
  }

  private target(w: number, h: number, old?: Target | null): Target {
    w = Math.max(1, Math.round(w));
    h = Math.max(1, Math.round(h));
    if (old && old.w === w && old.h === h) return old;
    const gl = this.gl;
    if (old) {
      gl.deleteFramebuffer(old.fb);
      gl.deleteTexture(old.tex);
    }
    const tex = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.SRGB8_ALPHA8, w, h);
    this.clampLinear();
    const fb = gl.createFramebuffer()!;
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    return { fb, tex, w, h };
  }

  /** A scratch target that keeps Lanczos' overshoot (half float where the
   *  engine can render to it, else 8-bit sRGB). */
  private lanczosTarget(w: number, h: number): Target {
    const gl = this.gl;
    w = Math.max(1, Math.round(w));
    h = Math.max(1, Math.round(h));
    const old = this.tmp[4];
    if (old && old.w === w && old.h === h) return old;
    if (old) {
      gl.deleteFramebuffer(old.fb);
      gl.deleteTexture(old.tex);
    }
    this.halfFloat ??= !!gl.getExtension("EXT_color_buffer_float");
    const tex = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texStorage2D(gl.TEXTURE_2D, 1, this.halfFloat ? gl.RGBA16F : gl.SRGB8_ALPHA8, w, h);
    this.clampLinear();
    const fb = gl.createFramebuffer()!;
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    this.tmp[4] = { fb, tex, w, h };
    return this.tmp[4];
  }
  private halfFloat: boolean | undefined;

  private clampLinear(mips = false) {
    const gl = this.gl;
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mips ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  }

  /** A scratch target, reused across frames. */
  private scratch(i: number, w: number, h: number): Target {
    this.tmp[i] = this.target(w, h, this.tmp[i]);
    return this.tmp[i];
  }

  private bindTarget(t: Target | null) {
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, t ? t.fb : null);
    const w = t ? t.w : this.canvas.width;
    const h = t ? t.h : this.canvas.height;
    gl.viewport(0, 0, w, h);
    return { w, h };
  }

  /** Draws `rect` (target px) with `prog`, uniforms set by `set`. */
  private draw(
    target: Target | null,
    name: string,
    src: string,
    rect: Rect,
    uniforms: Record<string, number | number[] | Float32Array>,
    textures: Record<string, WebGLTexture> = {},
  ) {
    const gl = this.gl;
    const { w, h } = this.bindTarget(target);
    const pr = this.prog(name, src);
    gl.useProgram(pr.p);
    const loc = (n: string) => {
      if (!pr.u.has(n)) pr.u.set(n, gl.getUniformLocation(pr.p, n));
      return pr.u.get(n)!;
    };
    gl.uniform4f(loc("uRect"), rect.x, rect.y, rect.w, rect.h);
    gl.uniform2f(loc("uTarget"), w, h);
    for (const [n, v] of Object.entries(uniforms)) {
      const l = loc(n);
      if (l == null) continue;
      if (typeof v === "number") {
        if (n === "uMode" || n === "uRow0" || n === "uRows") gl.uniform1i(l, v);
        else gl.uniform1f(l, v);
      } else if (v.length === 2) gl.uniform2fv(l, v);
      else if (v.length === 4) gl.uniform4fv(l, v);
    }
    let unit = 0;
    for (const [n, tex] of Object.entries(textures)) {
      gl.activeTexture(gl.TEXTURE0 + unit);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.uniform1i(loc(n), unit);
      unit++;
    }
    gl.bindVertexArray(this.quad);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    if (import.meta.env.DEV) {
      const err = gl.getError();
      if (err) console.error(`gl ${name}: 0x${err.toString(16)} (target ${target ? `${target.w}x${target.h}` : "canvas"})`);
    }
  }

  private blend(on: boolean) {
    const gl = this.gl;
    if (on) {
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    } else gl.disable(gl.BLEND);
  }

  // MARK: sources

  /** Uploads a video frame. A Lanczos shrink gets an sRGB texture (its
   *  passes read linear texels); anything else a plain 8-bit texture,
   *  bilinear on the gamma values as CoreImage does (`gamma: true`). */
  private uploadVideo(key: string, src: TexImageSource, lanczos: boolean) {
    const gl = this.gl;
    const w = (src as HTMLVideoElement).videoWidth || (src as ImageBitmap).width;
    const h = (src as HTMLVideoElement).videoHeight || (src as ImageBitmap).height;
    let v = this.videoTex.get(key);
    if (!v || v.w !== w || v.h !== h) {
      if (v) gl.deleteTexture(v.tex);
      v = { tex: gl.createTexture()!, w, h, gamma: !lanczos };
      this.videoTex.set(key, v);
    }
    gl.bindTexture(gl.TEXTURE_2D, v.tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, lanczos ? gl.SRGB8_ALPHA8 : gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, src);
    this.clampLinear();
    v.gamma = !lanczos;
    return v;
  }

  private uploadImage(file: string, img: HTMLImageElement | ImageBitmap) {
    const hit = this.imageTex.get(file);
    if (hit) return hit;
    const gl = this.gl;
    const tex = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    // The painting is a bilinear cover-fit with no prefilter, as on the Mac.
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, img);
    this.clampLinear(false);
    const out = { tex, w: img.width, h: img.height };
    this.imageTex.set(file, out);
    return out;
  }

  private cursor(src: Sources, style: string, tint: string, label: string, artHeight: number) {
    const key = `${style}/${tint}/${label}/${artHeight}`;
    const hit = this.cursorTex.get(key);
    if (hit) return hit;
    const art = src.cursorArt(style, tint, label, artHeight);
    if (!art) return null;
    const gl = this.gl;
    const tex = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    // Premultiplied sRGB bytes: decoded in the shader (an sRGB texture would
    // decode premultiplied values wrongly at the edges).
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, art.width, art.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, art.rgba);
    gl.generateMipmap(gl.TEXTURE_2D);
    this.clampLinear(true);
    const out = { tex, art };
    // Keep the cache small: a label edit makes a new sprite each keystroke.
    if (this.cursorTex.size > 24) {
      const [k0, v0] = this.cursorTex.entries().next().value!;
      gl.deleteTexture(v0.tex);
      this.cursorTex.delete(k0);
    }
    this.cursorTex.set(key, out);
    return out;
  }

  /** A text's picture as a texture, made once while it stays the same. */
  private text(src: Sources, t: TextPlan) {
    const words = t.words.map((w) => Math.round(w * 255));
    const key = JSON.stringify([t.lines, t.px, t.tracking, words, t.color, t.backing, t.shadow, t.highlight ?? null]);
    const hit = this.textTex.get(key);
    if (hit) return hit;
    const art = src.textArt(t);
    if (!art) return null;
    const gl = this.gl;
    const tex = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, art.width, art.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, art.rgba);
    gl.generateMipmap(gl.TEXTURE_2D);
    this.clampLinear(true);
    const out = { tex, art };
    // Word-by-word texts make a picture per step; keep only the recent ones.
    if (this.textTex.size > 32) {
      const [k0, v0] = this.textTex.entries().next().value!;
      gl.deleteTexture(v0.tex);
      this.textTex.delete(k0);
    }
    this.textTex.set(key, out);
    return out;
  }

  /** Separable gaussian of `t` in place (uses scratch 3 as the other half). */
  private blurTarget(t: Target, sigma: number) {
    if (sigma < 0.3) return;
    const other = this.scratch(3, t.w, t.h);
    const full = { x: 0, y: 0, w: t.w, h: t.h };
    this.blend(false);
    this.draw(other, "blur", BLUR, full, { uDir: [1, 0], uSigma: sigma }, { uTex: t.tex });
    this.draw(t, "blur", BLUR, full, { uDir: [0, 1], uSigma: sigma }, { uTex: other.tex });
  }

  // MARK: painting

  /** Size the drawing buffer to the element (device px). */
  resize(cssW: number, cssH: number, dpr = devicePixelRatio || 1) {
    const w = Math.max(1, Math.round(cssW * dpr));
    const h = Math.max(1, Math.round(cssH * dpr));
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
    }
  }

  /** Forget cached sources (a new backdrop picture, a closed recording). */
  forget() {
    const gl = this.gl;
    for (const v of this.imageTex.values()) gl.deleteTexture(v.tex);
    this.imageTex.clear();
    this.backdrop = null;
  }

  paint(plan: FramePlan, src: Sources) {
    const W = this.canvas.width;
    const H = this.canvas.height;
    this.k = W / plan.canvas.width;
    this.size = { w: W, h: H };
    const k = this.k;
    const S = (r: Rect): Rect => ({ x: r.x * k, y: r.y * k, w: r.w * k, h: r.h * k });
    const full = { x: 0, y: 0, w: W, h: H };
    const v4 = (r: Rect) => [r.x, r.y, r.w, r.h];

    this.work = this.target(W, H, this.work);
    const work = this.work;

    // 1. Backdrop.
    this.blend(false);
    const bd = this.backdropTexture(plan.backdrop, src);
    this.draw(work, "backdrop", BACKDROP, full, { uGrain: grain(plan.backdrop, src), uOpacity: 1 }, { uTex: bd.tex });
    this.blend(true);

    // 2. Shadow under the frame.
    if (plan.shadow) this.shadow(work, plan.shadow, S);

    // 3. Content, clipped to the rounded frame.
    const frame = S(plan.frame);
    const radius = plan.cornerRadius * k;
    const video = src.video(plan.take);
    // While a seek is in flight the take's last frame stands in (no flash).
    const v = video ? this.uploadVideo(`take-${plan.take}`, video, plan.source.lanczos) : this.videoTex.get(`take-${plan.take}`);
    if (v) {
      const common = { uFrame: v4(frame), uSrcRect: v4(plan.source.rect), uRadius: radius };
      if (plan.source.lanczos && !v.gamma) this.lanczos(work, plan, frame, radius, v.tex);
      else this.draw(work, "content", CONTENT, frame, { ...common, uSize: [v.w, v.h], uGamma: v.gamma ? 1 : 0, uBounds: v4(plan.source.bounds) }, { uTex: v.tex });
      // a. Hides, on the framed output.
      for (const h of plan.source.hides) this.hide(work, h, plan, frame, radius, v);
    } else {
      // Not loaded yet: the frame, black, as the Mac's player shows it.
      this.draw(work, "frameFill", FRAME_FILL, frame, { uFrame: v4(frame), uRadius: radius, uColor: [0, 0, 0, 1] });
    }

    // b. Ripples, under the cursor.
    for (const r of plan.ripples) {
      const c = { x: r.center.x * k, y: r.center.y * k };
      const R = r.radius * k;
      this.draw(work, "ripple", RIPPLE, { x: c.x - R, y: c.y - R, w: 2 * R, h: 2 * R }, {
        uCentre: [c.x, c.y],
        uR: R,
        uAlpha: r.alpha,
        uColor: premul(r.color),
        uFrame: v4(frame),
        uRadius: radius,
      });
    }

    // c. Cursor.
    const cur = plan.cursor;
    if (cur) {
      const sprite = this.cursor(src, cur.style, cur.tint, cur.label, cur.artHeight);
      if (sprite) {
        const s = (cur.height / cur.artHeight) * k;
        const dst = {
          x: cur.tip.x * k - sprite.art.tipX * s,
          y: cur.tip.y * k - sprite.art.tipY * s,
          w: sprite.art.width * s,
          h: sprite.art.height * s,
        };
        this.draw(work, "sprite", SPRITE, dst, { uDst: v4(dst), uFrame: v4(frame), uRadius: radius }, { uTex: sprite.tex });
      }
    }

    // 4. Webcam: the first candidate with a frame.
    for (const wc of plan.webcam) {
      const el = src.webcam(wc.file, wc.time);
      if (!el) continue;
      if (wc.opacity > 0.001) this.webcam(work, wc, el, S);
      break;
    }

    // 5. A clip fading in or out: the backdrop again, over everything.
    if (plan.veil > 0.001) {
      this.draw(work, "backdrop", BACKDROP, full, { uGrain: grain(plan.backdrop, src), uOpacity: plan.veil }, { uTex: bd.tex });
    }

    // 6. Words, on top: each picture centred, scaled about its centre.
    for (const t of plan.texts) {
      const pic = this.text(src, t);
      if (!pic) continue;
      const s = t.scale * k;
      const w = pic.art.width * s, h = pic.art.height * s;
      const dst = { x: t.center.x * k - w / 2, y: t.center.y * k - h / 2, w, h };
      this.draw(work, "text", TEXT, dst, { uDst: v4(dst), uOpacity: t.opacity }, { uTex: pic.tex });
    }

    // Present.
    this.blend(false);
    this.draw(null, "present", PRESENT, full, {}, { uTex: work.tex });
  }

  /** source.rect shrunk onto the frame with Lanczos-3, horizontally into a
   *  scratch target, then vertically into the frame. */
  private lanczos(t: Target, plan: FramePlan, frame: Rect, radius: number, tex: WebGLTexture) {
    const r = plan.source.rect, b = plan.source.bounds;
    const scaleY = Math.max(1, r.h / frame.h);
    const row0 = Math.max(Math.floor(b.y), Math.floor(r.y - 3 * scaleY) - 1);
    const row1 = Math.min(Math.ceil(b.y + b.h), Math.ceil(r.y + r.h + 3 * scaleY) + 1);
    const a = this.lanczosTarget(Math.round(frame.w), row1 - row0);
    this.blend(false);
    this.draw(a, "lanczosH", LANCZOS_H, { x: 0, y: 0, w: a.w, h: a.h }, {
      uSrcX: r.x,
      uSrcW: r.w,
      uOutW: a.w,
      uRow0: row0,
      uBounds: [b.x, b.y, b.w, b.h],
    }, { uTex: tex });
    this.blend(true);
    this.draw(t, "lanczosV", LANCZOS_V, frame, {
      uFrame: [frame.x, frame.y, frame.w, frame.h],
      uRadius: radius,
      uSrcY: r.y,
      uSrcH: r.h,
      uRow0: row0,
      uRows: a.h,
    }, { uTex: a.tex });
  }

  private shadow(t: Target, sh: ShadowPlan, S: (r: Rect) => Rect) {
    const k = this.k;
    const r = S(sh.rect);
    const sig = sh.sigma * k;
    const pad = sig * 3 + 2;
    this.draw(t, "shadow", SHADOW, { x: r.x - pad, y: r.y - pad, w: r.w + 2 * pad, h: r.h + 2 * pad }, {
      uRc: [r.x, r.y, r.w, r.h],
      uRadius: sh.radius * k,
      uSigma: sig,
      uColor: premul(sh.color),
    });
  }

  private hide(t: Target, h: HidePlan, plan: FramePlan, frame: Rect, radius: number, v: { tex: WebGLTexture; w: number; h: number; gamma: boolean }) {
    const sr = plan.source.rect;
    const fx = frame.w / sr.w;
    const fy = frame.h / sr.h;
    // The hide on the output, cut to the frame.
    const o = { x: frame.x + (h.rect.x - sr.x) * fx, y: frame.y + (h.rect.y - sr.y) * fy, w: h.rect.w * fx, h: h.rect.h * fy };
    const x0 = Math.max(o.x, frame.x), y0 = Math.max(o.y, frame.y);
    const x1 = Math.min(o.x + o.w, frame.x + frame.w), y1 = Math.min(o.y + o.h, frame.y + frame.h);
    if (x1 <= x0 || y1 <= y0) return;
    const vis = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    const base = {
      uFrame: [frame.x, frame.y, frame.w, frame.h],
      uSrcRect: [sr.x, sr.y, sr.w, sr.h],
      uRadius: radius,
      uHide: [h.rect.x, h.rect.y, h.rect.w, h.rect.h],
      uSize: [v.w, v.h],
      uGamma: v.gamma ? 1 : 0,
      uCell: Math.max(1, h.cell),
      uColor: premul(h.color),
    };
    if (h.style === "solid") {
      this.draw(t, "hide", HIDE, vis, { ...base, uMode: 0 });
    } else if (h.style === "pixelate") {
      this.draw(t, "hide", HIDE, vis, { ...base, uMode: 1 }, { uTex: v.tex });
    } else {
      // Grab the hide's own pixels (edges extended), blur twice, draw back.
      const a = this.scratch(2, o.w, o.h);
      const sig = h.sigma * fx;
      this.blend(false);
      this.draw(a, "grab", HIDE_GRAB, { x: 0, y: 0, w: a.w, h: a.h }, { ...base, uOut: [o.x, o.y, o.w, o.h] }, { uTex: v.tex });
      this.blurTarget(a, sig);
      this.blurTarget(a, sig / 2);
      this.blend(true);
      this.draw(t, "hide", HIDE, vis, { ...base, uMode: 2, uOut: [o.x, o.y, o.w, o.h] }, { uTex: a.tex });
    }
  }

  private webcam(t: Target, wc: WebcamPlan, el: TexImageSource, S: (r: Rect) => Rect) {
    const k = this.k;
    const v = this.uploadVideo(`cam-${wc.file}`, el, false);
    const rect = S(wc.rect);
    let cover = rect;
    const u: Record<string, number | number[]> = {
      uSize: [v.w, v.h],
      uFace: [rect.x, rect.y, rect.w, rect.h],
      uRadius: wc.radius * k,
      uMirror: wc.mirror ? 1 : 0,
      uOpacity: wc.opacity,
      uHasRim: 0,
      uHasShadow: 0,
    };
    const grow = (a: Rect, b: Rect): Rect => {
      const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
      return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
    };
    if (wc.rim) {
      const r = S(wc.rim.rect);
      Object.assign(u, { uHasRim: 1, uRim: [r.x, r.y, r.w, r.h], uRimRadius: wc.rim.radius * k, uRimColor: premul(wc.rim.color) });
      cover = grow(cover, r);
    }
    if (wc.shadow) {
      const r = S(wc.shadow.rect);
      const sig = wc.shadow.sigma * k;
      Object.assign(u, { uHasShadow: 1, uShRect: [r.x, r.y, r.w, r.h], uShRadius: wc.shadow.radius * k, uShSigma: sig, uShColor: premul(wc.shadow.color) });
      const pad = sig * 3 + 2;
      cover = grow(cover, { x: r.x - pad, y: r.y - pad, w: r.w + 2 * pad, h: r.h + 2 * pad });
    }
    this.draw(t, "webcam", WEBCAM, cover, u, { uTex: v.tex });
  }

  /** The backdrop at drawing size (or smaller when blurred), cached per look. */
  private backdropTexture(b: BackdropPlan, src: Sources): Target {
    const { w: W, h: H } = this.size;
    const img = b.kind === "image" ? src.image(b.file) : null;
    const usable = b.kind !== "image" || (img && img !== "failed");
    const shown: BackdropPlan = b.kind === "image" && img === "failed" ? b.fallback : b;
    const key = JSON.stringify([shown, W, H, b.kind === "image" ? !!usable : 0]);
    if (this.backdrop?.key === key) return this.backdrop.t;
    const k = this.k;
    const full = { x: 0, y: 0, w: W, h: H };
    let t: Target;
    this.blend(false);
    if (shown.kind === "image" && img && img !== "failed") {
      const tex = this.uploadImage(shown.file, img);
      // Big blurs work on a smaller copy (the result is smooth anyway).
      const sigma = shown.blurSigma * k;
      const f = sigma > 8 ? Math.min(8, Math.floor(sigma / 4)) : 1;
      t = this.target(W / f, H / f, this.backdrop?.t);
      const kk = Math.max(W / tex.w, H / tex.h);
      const sw = W / kk / tex.w, sh = H / kk / tex.h;
      this.draw(t, "image", IMAGE, { x: 0, y: 0, w: t.w, h: t.h }, {
        uDst: [0, 0, t.w, t.h],
        uSrc: [(1 - sw) / 2, (1 - sh) / 2, sw, sh],
        uFlipY: 0,
      }, { uTex: tex.tex });
      this.blurTarget(t, sigma / f);
    } else if (shown.kind === "image") {
      // Still loading: a quiet charcoal until it arrives.
      t = this.target(W, H, this.backdrop?.t);
      this.draw(t, "fill", FILL, full, { uColor: premul({ r: 0x17 / 255, g: 0x19 / 255, b: 0x1b / 255, a: 1 }) });
    } else if (shown.kind === "linear") {
      t = this.target(W, H, this.backdrop?.t);
      this.draw(t, "gradient", GRADIENT, full, {
        uFrom: [shown.from.x * k, shown.from.y * k],
        uTo: [shown.to.x * k, shown.to.y * k],
        uA: premul(shown.colorFrom),
        uB: premul(shown.colorTo),
      });
    } else {
      t = this.target(W, H, this.backdrop?.t);
      this.draw(t, "fill", FILL, full, { uColor: premul(shown.color) });
    }
    this.backdrop = { key, t };
    return t;
  }
}

function grain(b: BackdropPlan, src: Sources): number {
  if (b.kind !== "image") return b.grain;
  const img = src.image(b.file);
  return img === "failed" ? grain(b.fallback, src) : 0;
}
