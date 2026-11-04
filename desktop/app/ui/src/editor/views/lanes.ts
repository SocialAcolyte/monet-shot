// The timeline's lanes (MonetShotTimeline): its height (the strip and the
// zoom track, plus a lane for camera clips and a row per stack of texts),
// and which row each text sits in.
import type { TextOverlay } from "../core";
import type { EditorStore } from "../store.svelte";

export const MAX_TEXT_ROWS = 3;

/** Texts that overlap in time stack, each in the first row free when it starts. */
export function textRows(texts: TextOverlay[]): Map<string, number> {
  const ends: number[] = [];
  const out = new Map<string, number>();
  for (const o of [...texts].sort((a, b) => a.at - b.at)) {
    let row = ends.findIndex((e) => e <= o.at + 1e-6);
    if (row < 0) row = ends.length < MAX_TEXT_ROWS ? ends.length : MAX_TEXT_ROWS - 1;
    if (row < ends.length) ends[row] = Math.max(ends[row], o.at + o.duration);
    else ends.push(o.at + o.duration);
    out.set(o.id, row);
  }
  return out;
}

export const laneHeight = (s: EditorStore) =>
  158 + (s.edit.cameraClips.length ? 28 : 0) + Math.min(new Set(textRows(s.texts).values()).size, MAX_TEXT_ROWS) * 28;
