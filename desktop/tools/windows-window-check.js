// Dev script for the Windows CI run (windows-run.ps1, stage "window"). It runs
// in every page of the debug build:
//   picker: clicks the card of the test window ("MS Target Window"), as a
//           person picking it would;
//   pill:   once recording, logs where the hold-to-stop ring is on screen,
//           so the script can press it with the real mouse.
// Logs "window: …" lines.

const TARGET = "MS Target Window";

export default async function ({ view, call }) {
  const log = (m) => call("ui_log", { level: m.includes("FAIL") ? "error" : "info", message: `window: ${m}` });
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const until = async (f, ms) => {
    const t0 = performance.now();
    while (performance.now() - t0 < ms) {
      const v = f();
      if (v) return v;
      await wait(100);
    }
    return null;
  };

  if (view === "picker") {
    const card = await until(
      () => [...document.querySelectorAll(".card")].find((c) => c.querySelector(".title")?.textContent?.includes(TARGET)),
      20000,
    );
    if (!card) {
      const titles = [...document.querySelectorAll(".card .title")].map((t) => t.textContent).join(" | ");
      return log(`FAIL no picker card for "${TARGET}" (cards: ${titles})`);
    }
    await log(`picked the card "${card.querySelector(".title").textContent}"`);
    card.click();
  }

  if (view === "pill") {
    const ring = await until(() => document.querySelector(".hold"), 60000);
    if (!ring) return log("FAIL the pill never showed the stop ring");
    await wait(600); // let the pill finish its reveal
    const r = ring.getBoundingClientRect();
    const dpr = window.devicePixelRatio;
    // Screen pixels: the window's position plus the ring's centre.
    const x = Math.round((window.screenX + r.left + r.width / 2) * dpr);
    const y = Math.round((window.screenY + r.top + r.height / 2) * dpr);
    await log(`hold at ${x},${y} (dpr ${dpr})`);
  }
}
