// Dev script (MONETSHOT_DEV_SCRIPT) for the Linux run: what WebKitGTK does
// with the editor's <video>s: decode state, codec support, and whether a
// frame reaches a 2D canvas and a WebGL2 texture. Logs "diag: …".
export default async function ({ view, call }) {
  if (view !== "editor") return;
  const log = (m) => call("ui_log", { level: "info", message: `diag: ${m}` });
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  await wait(8000);
  const probe = document.createElement("video");
  await log(`canPlayType hvc1=${probe.canPlayType('video/mp4; codecs="hvc1.1.6.L120.90"')} avc1=${probe.canPlayType('video/mp4; codecs="avc1.640028"')} mov=${probe.canPlayType("video/quicktime")}`);
  await log(`requestVideoFrameCallback=${"requestVideoFrameCallback" in HTMLVideoElement.prototype}`);
  const gl0 = document.createElement("canvas").getContext("webgl2");
  const dbg = gl0?.getExtension("WEBGL_debug_renderer_info");
  await log(`webgl2=${!!gl0} renderer=${dbg ? gl0.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : "?"} float-color=${!!gl0?.getExtension("EXT_color_buffer_float")}`);
  const first = document.querySelector("video");
  const base = (first?.currentSrc || first?.src || "").replace(/(localhost\/).*$/, "$1");
  const original = base + encodeURIComponent("/home/run/recordings/2026-11-01 21.23.59.reel/screen.mov");
  await log(`asset base=${base}`);
  for (const url of first ? [first.currentSrc || first.src, original] : []) {
    for (const range of [null, "bytes=0-99", "bytes=1000-"]) {
      try {
        const r = await fetch(url, range ? { headers: { Range: range } } : {});
        const n = (await r.arrayBuffer()).byteLength;
        await log(`asset ${url.slice(-24)} range=${range}: ${r.status} type=${r.headers.get("content-type")} content-range=${r.headers.get("content-range")} accept-ranges=${r.headers.get("accept-ranges")} bytes=${n}`);
      } catch (e) {
        await log(`asset fetch range=${range} threw: ${e}`);
      }
    }
  }
  const vids = [...document.querySelectorAll("video")];
  await log(`videos in page: ${vids.length}`);
  for (const [i, v] of vids.entries()) {
    const s = () => `rs=${v.readyState} ns=${v.networkState} ${v.videoWidth}x${v.videoHeight} t=${v.currentTime.toFixed(2)} paused=${v.paused} err=${v.error?.code ?? "-"} ${v.error?.message ?? ""}`;
    await log(`#${i} src=${decodeURIComponent(v.currentSrc).slice(-60)} ${s()}`);
    v.muted = true;
    try {
      await v.play();
    } catch (e) {
      await log(`#${i} play() rejected: ${e}`);
    }
    await wait(2000);
    await log(`#${i} after 2 s play: ${s()}`);
    v.pause();
    const sum = (px) => px.reduce((a, b) => a + b, 0);
    try {
      const c = document.createElement("canvas");
      c.width = c.height = 32;
      const g = c.getContext("2d");
      g.drawImage(v, 0, 0, 32, 32);
      await log(`#${i} 2d drawImage pixel sum=${sum(g.getImageData(0, 0, 32, 32).data)}`);
    } catch (e) {
      await log(`#${i} 2d drawImage threw: ${e}`);
    }
    try {
      const c = document.createElement("canvas");
      const gl = c.getContext("webgl2");
      const tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, v);
      const e1 = gl.getError();
      const fb = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
      const px = new Uint8Array(4 * 16);
      gl.readPixels(0, 0, 4, 4, gl.RGBA, gl.UNSIGNED_BYTE, px);
      await log(`#${i} webgl texImage2D(video) err=${e1} fb=${gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE} pixel sum=${sum(px)}`);
    } catch (e) {
      await log(`#${i} webgl threw: ${e}`);
    }
  }
  // The same files over plain HTTP (python -m http.server 8765 in /), to tell
  // the URL scheme apart from the codec.
  for (const url of ["http://127.0.0.1:8765/root/.cache/com.connorhood.monetshot/proxies/1el53hu.mp4", "http://127.0.0.1:8765/home/run/recordings/2026-11-01%2021.23.59.reel/screen.mov"]) {
    const v = document.createElement("video");
    v.muted = true;
    v.src = url;
    document.body.appendChild(v);
    await new Promise((r) => {
      v.onloadeddata = v.onerror = r;
      setTimeout(r, 15000);
    });
    try {
      await v.play();
    } catch (e) {
      await log(`http play() rejected: ${e}`);
    }
    await wait(1500);
    await log(`http ${url.slice(-30)}: rs=${v.readyState} ${v.videoWidth}x${v.videoHeight} t=${v.currentTime.toFixed(2)} err=${v.error?.code ?? "-"}`);
    // Cross-origin, so the canvas is tainted; a frame count is what we can see.
    const q = v.getVideoPlaybackQuality?.();
    if (q) await log(`http frames decoded=${q.totalVideoFrames} dropped=${q.droppedVideoFrames}`);
    v.remove();
  }
  // Through the app's loopback media server (media_url), crossOrigin set, as the editor would.
  for (const path of ["/root/.cache/com.connorhood.monetshot/proxies/1el53hu.mp4", "/home/run/recordings/2026-11-01 21.23.59.reel/screen.mov"]) {
    let url;
    try {
      url = await call("media_url", { path });
    } catch (e) {
      await log(`media_url failed: ${e}`);
      continue;
    }
    const v = document.createElement("video");
    v.muted = true;
    v.crossOrigin = "anonymous";
    v.src = url;
    document.body.appendChild(v);
    await new Promise((r) => {
      v.onloadeddata = v.onerror = r;
      setTimeout(r, 20000);
    });
    const seen = {};
    for (const ev of ["play", "playing", "waiting", "stalled", "timeupdate", "seeked", "pause", "ended"]) v.addEventListener(ev, () => (seen[ev] = (seen[ev] ?? 0) + 1));
    let frames = 0;
    if (v.requestVideoFrameCallback) {
      const tick = () => {
        frames++;
        v.requestVideoFrameCallback(tick);
      };
      v.requestVideoFrameCallback(tick);
    }
    try {
      await v.play();
      await log(`media play() resolved, paused=${v.paused} visibility=${document.visibilityState} hasFocus=${document.hasFocus()}`);
    } catch (e) {
      await log(`media play() rejected: ${e}`);
    }
    await wait(10000);
    await log(`media events ${JSON.stringify(seen)} rVFC frames=${frames}`);
    v.pause();
    const q = v.getVideoPlaybackQuality?.();
    await log(`media ${url.replace(/[0-9a-f]{32}/, "<token>")}: rs=${v.readyState} ${v.videoWidth}x${v.videoHeight} t=${v.currentTime.toFixed(2)} err=${v.error?.code ?? "-"} decoded=${q?.totalVideoFrames}`);
    try {
      const c = document.createElement("canvas");
      const gl = c.getContext("webgl2");
      const tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, v);
      const e1 = gl.getError();
      const fb = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
      const px = new Uint8Array(4 * 64 * 64);
      gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, px);
      await log(`media webgl texImage2D err=${e1} pixel sum=${px.reduce((a, b) => a + b, 0)}`);
    } catch (e) {
      await log(`media webgl threw: ${e}`);
    }
    v.remove();
  }
  await log("done");
}
