import { mount } from "svelte";
import "./app.css";
import Pill from "./views/Pill.svelte";
import Home from "./views/Home.svelte";
import Editor from "./views/Editor.svelte";
import Picker from "./views/Picker.svelte";
import Bubble from "./views/Bubble.svelte";
import { call, inTauri } from "./lib/ipc";

if (!inTauri) await import("./lib/mock");
else {
  // Uncaught page errors go to the app's log.
  const send = (message: string) => call("ui_log", { level: "error", message }).catch(() => {});
  addEventListener("error", (e) => send(`${e.message} at ${e.filename}:${e.lineno}`));
  addEventListener("unhandledrejection", (e) => send(`unhandled: ${e.reason?.stack ?? e.reason}`));
  const err = console.error.bind(console);
  console.error = (...a: unknown[]) => {
    err(...a);
    send(a.map((x) => (x instanceof Error ? x.stack ?? x.message : typeof x === "string" ? x : JSON.stringify(x))).join(" "));
  };
}

// One page, three windows: the app opens index.html?view=pill|home|editor.
const params = new URLSearchParams(location.search);
const view = params.get("view") ?? "home";
const target = document.getElementById("app")!;

if (view === "pill" || view === "bubble") {
  document.documentElement.classList.add("transparent");
  document.body.classList.add("transparent");
  mount(view === "pill" ? Pill : Bubble, { target });
} else if (view === "picker") {
  mount(Picker, { target });
} else if (view === "editor") {
  mount(Editor, { target, props: { reel: params.get("reel") ?? "" } });
} else {
  mount(Home, { target });
}

// Dev builds: ?devscript=<abs path> runs a check script (see windows.rs).
const devscript = params.get("devscript");
if (import.meta.env.DEV && devscript) {
  // Vite serves files outside its root at /@fs/<abs path>; a Windows path
  // (C:\a\b.js) becomes /@fs/C:/a/b.js.
  const abs = devscript.replace(/\\/g, "/");
  import(/* @vite-ignore */ `/@fs${abs.startsWith("/") ? "" : "/"}${abs}`)
    .then((m) => m.default?.({ view, call }))
    .catch((e) => console.error("devscript", e));
}
