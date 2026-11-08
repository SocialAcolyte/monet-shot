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
  /** "calm" | "steady" | "upbeat" (the library's own reading). */
  tempo?: string;
  /** 0...1: how much drive it has. */
  energy?: number;
  /** Its beat, read once when the library was made (or when you chose your file). */
  grid?: Grid | null;
  /** Seconds in where it's best to begin. */
  start?: number;
  /** A small waveform for the list, 0...1. */
  peaks?: number[];
  [k: string]: unknown;
}

export interface Grid {
  bar: number;
  firstDownbeat: number;
  lifts: number[];
}

export const tempos = ["calm", "steady", "upbeat"] as const;
export type Tempo = (typeof tempos)[number];

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
  { id: "punchy", name: "Punchy", feel: "punchy", tint: "#a0505e" },
  { id: "classical", name: "Classical", feel: "classical", tint: "#5a6f88" },
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
/** The path in a file:// URL (file:///D:/x is D:/x on Windows). */
export function urlPath(url: string): string | null {
  if (!url.startsWith("file://")) return null;
  const p = decodeURIComponent(url.slice("file://".length));
  return /^\/[A-Za-z]:/.test(p) ? p.slice(1) : p;
}

export async function playable(url: string | undefined, media = false): Promise<string | null> {
  if (!url) return null;
  if (!url.startsWith("file://")) return /^https?:/.test(url) ? url : null;
  const path = urlPath(url)!;
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

/** Where `song` sits under this video (MusicFit.place): from a downbeat at
 *  its good start (its first lift for a vertical video), the end fade on a
 *  phrase line; the level and fades of any music it replaces. */
export function fitted(store: EditorStore, song: Song, file: string): MusicChoice {
  const old = store.edit.music;
  const p = store.c.musicPlace(song.grid ?? null, song.duration, store.duration, song.start, store.isVertical);
  return { track: song, file, offset: p.offset, volume: old?.volume ?? 0.8, fadeIn: old?.fadeIn ?? true, fadeOut: old?.fadeOut ?? true };
}

/** Plays the edit from the top with `song` under it; again to pause or go on. */
export function toggleAudition(store: EditorStore, song: Song) {
  if (store.audition?.track.id === song.id) {
    store.togglePlay();
    return;
  }
  const path = urlPath(song.audioURL);
  if (!path) return;
  store.audition = fitted(store, song, path);
  store.seek(0);
  store.playing = true;
}

export function stopAudition(store: EditorStore) {
  if (!store.audition) return;
  store.audition = null;
  store.playing = false;
}

/** Copies the track into the recording and lays it under the video,
 *  fitted to it, keeping the level and fades of any music it replaces. */
export async function useMusic(store: EditorStore, song: Song): Promise<boolean> {
  try {
    const file = await call<string>("music_add", { folder: store.folder, song });
    const old = store.edit.music;
    stopAudition(store);
    let track = song;
    if (!track.grid && inTauri) {
      // a file of your own: find its beat once, and keep it with the choice
      const shape = await call<{ wave: number[]; grid: Grid | null }>("music_shape", { folder: store.folder, file }).catch(() => null);
      if (shape?.grid) track = { ...track, grid: shape.grid };
    }
    const choice = fitted(store, track, file);
    store.update((e) => (e.music = choice));
    if (old && old.file !== file) call("recording_remove_file", { folder: store.folder, name: old.file });
    await loadShape(store, true);
    refreshVoice(store);
    store.closeMusic();
    return true;
  } catch (e) {
    console.error("music", e);
    return false;
  }
}

/** A few tracks for this video (MusicSuggest.rank, in core). */
export async function suggestions(store: EditorStore, favourites: string[]): Promise<Song[]> {
  return call<Song[]>("music_suggest", {
    length: store.duration,
    mood: store.musicMood,
    vertical: store.isVertical,
    favourites,
  });
}

// Favourites, remembered between launches (this app's own storage).
const FAVOURITES = "monetshot.musicFavourites";

export function loadFavourites(): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(FAVOURITES) ?? "[]");
    return Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
}

export function saveFavourites(ids: string[]) {
  try {
    localStorage.setItem(FAVOURITES, JSON.stringify([...ids].sort()));
  } catch {
    // private storage off: favourites last this session only
  }
}

let voiceTimer = 0;
/** Re-reads where the music ducks (the edit's voices), shortly after a change. */
export function refreshVoice(store: EditorStore, delay = 0) {
  clearTimeout(voiceTimer);
  voiceTimer = window.setTimeout(async () => {
    if (!inTauri || !(store.edit.music || store.audition) || !store.edit.cameraLook?.duckMusic) {
      store.musicVoice = [];
      return;
    }
    try {
      store.musicVoice = await call<[number, number][]>("music_voice", { folder: store.folder, edit: store.edit });
    } catch (e) {
      console.error("music voice", e);
    }
  }, delay);
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
    store.musicGrid = (m.track.grid as Grid | undefined) ?? s.grid;
  } catch (e) {
    console.error("music shape", e);
  }
}
