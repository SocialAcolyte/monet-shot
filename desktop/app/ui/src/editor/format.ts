/** "0:03.2" (TransportBar.stamp). */
export function stamp(t: number): string {
  const s = Math.max(0, t);
  const sec = (s % 60).toFixed(1).padStart(4, "0");
  return `${Math.floor(s / 60)}:${sec}`;
}

/** "42%" */
export const percent = (v: number) => `${Math.round(v * 100)}%`;
