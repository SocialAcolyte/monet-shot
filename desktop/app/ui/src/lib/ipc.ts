// The app's commands and events (docs/porting/contracts/ipc.md), typed. Out
// of Tauri (vite dev in Safari, to check the UI on WebKit) a small mock
// answers instead, so every page can be opened in a plain browser.
import type { UnlistenFn } from "@tauri-apps/api/event";

export const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export type Phase =
  | { kind: "idle" }
  | { kind: "picking" }
  | { kind: "countdown"; n: number }
  | { kind: "starting" }
  | { kind: "recording"; since: number }
  | { kind: "saving" };

export interface BarState {
  phase: Phase;
  paused: boolean;
  pausedTotal: number;
  pausedSince: number | null;
  problem: string | null;
  cameraToo: boolean;
  /** "Record Vertical": new recordings open made for phones. */
  vertical: boolean;
}

type Mock = (args?: Record<string, unknown>) => unknown;
const mocks: Record<string, Mock> = {};
const mockListeners: Record<string, Array<(p: unknown) => void>> = {};

/** Registers the browser stand-in for a command (see mock.ts). */
export function mock(cmd: string, f: Mock) {
  mocks[cmd] = f;
}

export function mockEmit(event: string, payload: unknown) {
  for (const f of mockListeners[event] ?? []) f(payload);
}

export async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (inTauri) {
    const { invoke } = await import("@tauri-apps/api/core");
    return invoke<T>(cmd, args);
  }
  const m = mocks[cmd];
  if (!m) throw new Error(`no mock for ${cmd}`);
  return (await m(args)) as T;
}

export async function on<T>(event: string, f: (payload: T) => void): Promise<UnlistenFn> {
  if (inTauri) {
    const { listen } = await import("@tauri-apps/api/event");
    return listen<T>(event, (e) => f(e.payload));
  }
  (mockListeners[event] ??= []).push(f as (p: unknown) => void);
  return () => {
    mockListeners[event] = (mockListeners[event] ?? []).filter((g) => g !== f);
  };
}

/** Recorded seconds at `now` (ms), not counting pauses (MenuBarModel.elapsed). */
export function elapsed(s: BarState, now: number): number {
  if (s.phase.kind !== "recording") return 0;
  const pausedNow = s.pausedSince != null ? now - s.pausedSince : 0;
  return Math.max(0, (now - s.phase.since - s.pausedTotal - pausedNow) / 1000);
}

/** "0:07" or "12:41" (MenuBarModel.clock). */
export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const two = (n: number) => String(n).padStart(2, "0");
  return s >= 3600
    ? `${Math.floor(s / 3600)}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}`
    : `${Math.floor(s / 60)}:${two(s % 60)}`;
}
