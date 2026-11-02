// Local files as URLs the page can load (Tauri's asset protocol).
import { call, inTauri } from "./ipc";
import { isLinux } from "./platform";

let convert: ((p: string) => string) | null = null;
if (inTauri) convert = (await import("@tauri-apps/api/core")).convertFileSrc;

export function fileUrl(path: string, version?: string | number): string {
  const base = convert ? convert(path) : `/@fs${path}`;
  return version != null ? `${base}?v=${version}` : base;
}

/** A URL a <video> can stream. WebKitGTK's media stack can't read Tauri's
 *  asset protocol (FormatError), so on Linux media comes over ms-capture's
 *  loopback server (`media_url`: Range + CORS); elsewhere the asset protocol. */
export async function mediaUrl(path: string): Promise<string> {
  if (inTauri && isLinux) return call<string>("media_url", { path });
  return fileUrl(path);
}

/** "0:42" (MusicTime.clock). */
export function minutes(s: number): string {
  const t = Math.max(0, Math.floor(s));
  return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`;
}
