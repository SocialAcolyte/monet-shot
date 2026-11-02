// Music under the video (owner: ms-capture): the library's songs, adding one
// to the recording, and its waveform + beat grid for the snippet picker.
// Ported from MusicCatalog / the music part of the Mac's EditorModel.
import type { EditorStore } from "../store.svelte";
import type { MusicChoice } from "../core";
import { call, inTauri } from "../../lib/ipc";
import { isMac, isWindows } from "../../lib/platform";

/** A song as library.json and edit.json carry it. */
export interface Song {
  id: string;
  title: string;
  artist: string;
  album?: string;
  duration: number;
  genres: string[];
  license: string;
  licenseVersion?: string;
  licenseURL?: string;
  audioURL: string;
  artworkURL?: string;
  pageURL?: string;
  attribution?: string;
  bpm?: number;
  about?: string;
  instruments?: string;
  [k: string]: unknown;
}

export interface Mood {
  id: string;
  name: string;
  feel: string;
  tint: string;
}

/** Moods for browsing: each is one of the composer's own "feel" tags. */
export const moods: Mood[] = [
  { id: "dreamy", name: "Dreamy", feel: "dreamy", tint: "#6a5b8a" },
  { id: "grooving", name: "Grooving", feel: "grooving", tint: "#c96f4a" },
  { id: "sunny", name: "Sunny", feel: "sunny", tint: "#b89b4a" },
  { id: "mellow", name: "Mellow", feel: "mellow", tint: "#5f7a73" },
  { id: "impressionist", name: "Impressionist", feel: "impressionist", tint: "#5a6f88" },
];

export function licenseLabel(s: Song): string {
  switch (s.license) {
    case "cc0":
      return "CC0";
    case "pdm":
      return "Public domain";
    case "own":
      return "Your file";
    default:
      return `CC ${s.license.toUpperCase()}${s.licenseVersion ? ` ${s.licenseVersion}` : ""}`;
  }
}

/** True when the licence asks for a credit wherever the music is used. */
export const needsCredit = (s: Song) => !["cc0", "pdm", "own"].includes(s.license);

export const creditText = (s: Song) => s.attribution ?? `"${s.title}" by ${s.artist}, ${licenseLabel(s)}`;

/** "3:07" (MusicTime.clock). */
export const clock = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

/** A file:// URL (or path) as something the page can load. Images use the
 *  asset protocol; audio on Linux goes through the app's loopback media
 *  server, because WebKitGTK's player can't stream from asset:// (FormatError). */
export async function playable(url: string | undefined, media = false): Promise<string | null> {
  if (!url) return null;
  if (!url.startsWith("file://")) return /^https?:/.test(url) ? url : null;
  const path = decodeURIComponent(url.slice("file://".length));
  if (!inTauri) return null;
  if (media && !isMac && !isWindows) return call<string>("media_url", { path }).catch(() => null);
  const { convertFileSrc } = await import("@tauri-apps/api/core");
  return convertFileSrc(path);
}

/** The generated cover's colour: the track's feel, else a stable pick by title. */
export function coverTint(s: Song): string {
  const feel = s.genres[0]?.toLowerCase() ?? "";
  const m = moods.find((x) => x.feel === feel);
  if (m) return m.tint;
  let h = 5381;
  for (const b of new TextEncoder().encode(s.title)) h = (Math.imul(h, 33) ^ b) >>> 0;
  return moods[h % moods.length].tint;
}

export async function library(query: string, mood: string | null): Promise<Song[]> {
  return call<Song[]>("music_library", { query, mood });
}

/** Copies the track into the recording and lays it under the video,
 *  keeping the level and fades of any music it replaces. */
export async function useMusic(store: EditorStore, song: Song): Promise<boolean> {
  try {
    const file = await call<string>("music_add", { folder: store.folder, song });
    const old = store.edit.music;
    const choice: MusicChoice = {
      track: song,
      file,
      offset: 0,
      volume: old?.volume ?? 0.8,
      fadeIn: old?.fadeIn ?? true,
      fadeOut: old?.fadeOut ?? true,
    };
    store.update((e) => (e.music = choice));
    if (old && old.file !== file) call("recording_remove_file", { folder: store.folder, name: old.file });
    await loadShape(store, true);
    store.closeMusic();
    return true;
  } catch (e) {
    console.error("music", e);
    return false;
  }
}

export function removeMusic(store: EditorStore) {
  const m = store.edit.music;
  if (!m) return;
  store.update((e) => (e.music = null));
  call("recording_remove_file", { folder: store.folder, name: m.file });
  store.musicWave = [];
  store.musicGrid = null;
  shaped.delete(store);
}

export async function copyCredit(store: EditorStore) {
  const t = store.edit.music?.track as Song | undefined;
  if (t) await navigator.clipboard.writeText(creditText(t));
}

/** Which file each editor's wave/grid were read from. */
const shaped = new WeakMap<EditorStore, string>();

/** The waveform and beat grid of the music in use (read once per file). */
export async function loadShape(store: EditorStore, force = false) {
  const m = store.edit.music;
  if (!m) {
    store.musicWave = [];
    store.musicGrid = null;
    return;
  }
  if (!force && shaped.get(store) === m.file) return;
  shaped.set(store, m.file);
  if (!inTauri) return;
  try {
    const s = await call<{ wave: number[]; grid: { bar: number; firstDownbeat: number; lifts: number[] } | null }>("music_shape", {
      folder: store.folder,
      file: m.file,
    });
    if (store.edit.music?.file !== m.file) return;
    store.musicWave = s.wave;
    store.musicGrid = s.grid;
  } catch (e) {
    console.error("music shape", e);
  }
}
