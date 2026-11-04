// The preview's sources and clock. Each take plays from its own <video>
// (the takes are separate files, as on the Mac); while playing, the video
// of the clip on screen is the clock, so picture and time never drift.
// At a clip's end the next clip's video takes over.

import { fileUrl, mediaUrl } from "../lib/files";
import { call, inTauri } from "../lib/ipc";
import { isLinux } from "../lib/platform";
import type { Sources } from "./painter";
import type { CursorArt, FramePlan, TextArt, TextPlan } from "./plan";
import type { EditorStore } from "./store.svelte";

const join = (folder: string, file: string) => `${folder.replace(/[\\/]+$/, "")}/${file}`;

export class Playback implements Sources {
  private takes: HTMLVideoElement[] = [];
  private cams = new Map<string, HTMLVideoElement>();
  private images = new Map<string, HTMLImageElement | "failed">();
  private box: HTMLDivElement;
  /** Videos with a decoded frame at their current time (where known). */
  private framed = new WeakMap<HTMLVideoElement, boolean>();
  private ready(v: HTMLVideoElement | undefined): v is HTMLVideoElement {
    return !!v && v.readyState >= 2 && v.videoWidth > 0 && !v.seeking && this.framed.get(v) !== false;
  }
  /** Something changed that the picture should show. */
  dirty = true;
  /** A sentence for over the preview (a video that can't play here), or null. */
  onNotice: (text: string | null) => void = () => {};
  /** The clip being played (index into spans) while playing. */
  private span = -1;
  /** The plan `tick` last returned (the one being painted). */
  private current: FramePlan | null = null;

  constructor(private store: EditorStore) {
    // Off-screen but in the document, so every engine keeps decoding frames.
    this.box = document.createElement("div");
    this.box.style.cssText = "position:fixed;left:-10px;top:-10px;width:1px;height:1px;overflow:hidden;opacity:0;pointer-events:none";
    document.body.appendChild(this.box);
    this.syncTakes();
  }

  destroy() {
    for (const v of [...this.takes, ...this.cams.values()]) {
      v.pause();
      v.removeAttribute("src");
      v.load();
    }
    this.box.remove();
  }

  private makeVideo(path: string, muted: boolean): HTMLVideoElement {
    const v = document.createElement("video");
    v.muted = muted;
    v.playsInline = true;
    v.preload = "auto";
    v.crossOrigin = "anonymous";
    mediaUrl(path).then(
      (url) => (v.src = url),
      (e) => console.error("media url", path, e),
    );
    this.fallBack(v, path);
    const wake = () => (this.dirty = true);
    v.addEventListener("loadeddata", wake);
    v.addEventListener("seeked", wake);
    // A seeked video can report itself ready before its new frame is
    // decoded (WebKit uploads an empty texture then): where the engine says
    // when a frame is on screen, only that counts.
    const rvfc = (v as HTMLVideoElement & { requestVideoFrameCallback?: (cb: () => void) => number }).requestVideoFrameCallback;
    if (rvfc) {
      this.framed.set(v, false);
      v.addEventListener("seeking", () => this.framed.set(v, false));
      const onFrame = () => {
        this.framed.set(v, true);
        this.dirty = true;
        rvfc.call(v, onFrame);
      };
      rvfc.call(v, onFrame);
    }
    this.box.appendChild(v);
    return v;
  }

  /** Takes made on a Mac are HEVC, which WebView2 rarely plays and
   *  WebKitGTK only with gst-libav. When this engine can't show a file, the
   *  preview switches to an H.264 copy with the same frames and times
   *  (ms-capture's video_proxy; the recording itself is untouched). */
  private fallBack(v: HTMLVideoElement, path: string) {
    if (!inTauri) return;
    let tried = false;
    const swap = async () => {
      if (tried) return;
      tried = true;
      this.onNotice("Getting this video ready for this computer…");
      try {
        const proxy = await call<string>("video_proxy", { path });
        const at = v.currentTime;
        v.addEventListener("loadedmetadata", () => (v.currentTime = at), { once: true });
        v.src = await mediaUrl(proxy);
        this.onNotice(null);
      } catch (e) {
        console.error("video_proxy", e);
        this.onNotice(
          !isLinux
            ? "Can't play this video here. Exporting still works."
            : "Can't play this video. Install GStreamer's libav plugin: sudo pacman -S gst-libav (Arch) or sudo apt install gstreamer1.0-libav (Ubuntu), then reopen it. Export still works.",
        );
      }
    };
    v.addEventListener("error", () => {
      const code = v.error?.code;
      if (code === 3 || code === 4) swap();
    });
    v.addEventListener("loadedmetadata", () => {
      if (v.videoWidth === 0) swap();
    });
    // Some engines show nothing and say nothing: no frame in 3 s is a no.
    setTimeout(() => {
      if (!tried && (v.readyState < 2 || v.videoWidth === 0) && !v.error) swap();
    }, 3000);
  }

  /** One video per take (new takes arrive with Add clip / Record a take). */
  syncTakes() {
    const t = this.store.takes;
    while (this.takes.length < t.length) {
      const i = this.takes.length;
      this.takes.push(this.makeVideo(t[i].video, false));
    }
  }

  // MARK: Sources


  video(take: number): TexImageSource | null {
    const v = this.takes[take];
    return this.ready(v) ? v : null;
  }

  webcam(file: string, time: number): TexImageSource | null {
    let v = this.cams.get(file);
    if (!v) {
      v = this.makeVideo(join(this.store.folder, file), this.store.muted);
      this.cams.set(file, v);
    }
    if (time < 0 || (v.duration && time > v.duration)) return null;
    // A take's own camera runs with its clip; one recorded over the edit, in real time.
    const plan = this.current;
    const own = plan?.webcam.find((w) => w.file === file)?.kind === "take";
    this.follow(v, time, own && plan ? plan.speed : 1);
    return this.ready(v) ? v : null;
  }

  image(file: string) {
    const hit = this.images.get(file);
    if (hit) return hit === "failed" || hit.complete ? hit : null;
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => (this.dirty = true);
    img.onerror = () => {
      this.images.set(file, "failed");
      this.dirty = true;
    };
    img.src = fileUrl(join(this.store.folder, file));
    this.images.set(file, img);
    return null;
  }

  /** A new backdrop picture under an old name: load it again. */
  forgetImage(file: string) {
    this.images.delete(file);
  }

  cursorArt(style: string, tint: string, label: string, artHeight: number): CursorArt | null {
    return this.store.cursorArt(style, tint, label, artHeight);
  }

  textArt(text: TextPlan): TextArt | null {
    return this.store.textArt(text);
  }

  // MARK: clock

  /** Keeps a video near `time`: seeks when far off, plays along while
   *  playing at `rate` (a clip's speed; the browser keeps the pitch). */
  private follow(v: HTMLVideoElement, time: number, rate = 1) {
    const playing = this.store.playing;
    if (v.playbackRate !== rate) v.playbackRate = rate;
    if (playing) {
      if (Math.abs(v.currentTime - time) > 0.25) v.currentTime = time;
      if (v.paused) v.play().catch(() => {});
    } else {
      if (!v.paused) v.pause();
      if (Math.abs(v.currentTime - time) > 1 / 240 && !v.seeking) v.currentTime = time;
    }
  }

  /** Called every animation frame: advances the clock, returns the plan to draw. */
  tick(): FramePlan | null {
    const s = this.store;
    const ed = s.editor;
    const d = s.duration;
    if (s.playing) {
      const spans = ed.spans();
      if (this.span < 0 || !spans[this.span]) this.span = ed.locate(s.time).index;
      const sp = spans[this.span];
      const v = this.takes[sp?.take ?? -1];
      if (sp && v && !v.paused && !v.seeking && v.readyState >= 2) {
        // The video is the clock.
        const vt = v.currentTime;
        if (vt >= sp.end - 0.004) {
          // This clip is over: on to the next, or the end.
          this.span++;
          if (!spans[this.span]) {
            s.playing = false;
            s.time = d;
            this.span = -1;
          } else {
            s.time = spans[this.span].at;
          }
        } else if (vt >= sp.start - 0.1) {
          s.time = Math.min(d, sp.at + Math.max(0, vt - sp.start) / sp.speed);
        }
      }
      this.dirty = true;
    } else {
      this.span = -1;
    }
    if (!this.dirty) return null;
    this.dirty = s.playing;
    const plan = ed.plan(Math.min(s.time, Math.max(0, d - 0.0005)));
    this.current = plan;
    // Every take but the one on screen rests.
    this.takes.forEach((v, i) => {
      if (i === plan.take) {
        v.muted = this.store.muted;
        this.follow(v, plan.takeTime, plan.speed);
      } else if (!v.paused) v.pause();
    });
    for (const [file, v] of this.cams) {
      v.muted = this.store.muted;
      if (!plan.webcam.some((w) => w.file === file) && !v.paused) v.pause();
    }
    return plan;
  }
}
