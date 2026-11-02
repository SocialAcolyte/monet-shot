// Motion.swift in the web: springs that settle, a crossfade under Reduce
// Motion. Svelte transitions take an easing function, so the springs are
// sampled from the real damped-spring equation.
import { cubicOut } from "svelte/easing";
import type { TransitionConfig } from "svelte/transition";

export const reduceMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

/** SwiftUI's .spring(response:dampingFraction:) as an easing over its settle time. */
function spring(response: number, damping: number) {
  const w = (2 * Math.PI) / response;
  const zeta = damping;
  const wd = w * Math.sqrt(1 - zeta * zeta);
  // Settle time: the envelope below 0.1 %.
  const settle = -Math.log(0.001) / (zeta * w);
  const ease = (t: number) => {
    const s = t * settle;
    return 1 - Math.exp(-zeta * w * s) * (Math.cos(wd * s) + ((zeta * w) / wd) * Math.sin(wd * s));
  };
  return { ease, ms: settle * 1000 };
}

export const base = spring(0.35, 0.72);
export const snappy = spring(0.25, 0.6);
export const tick = spring(0.18, 0.85);
export const holdDuration = 600;

/** Scale-and-fade from the leading edge (Motion.reveal); a plain fade reduced. */
export function reveal(_node: Element): TransitionConfig {
  if (reduceMotion()) return { duration: 150, css: (t) => `opacity:${t}` };
  return {
    duration: base.ms,
    easing: base.ease,
    css: (t) => `opacity:${Math.min(1, t)};transform:scale(${0.6 + 0.4 * t});transform-origin:left center`,
  };
}

/** A plain fade (.opacity) at the base pace. */
export function fade(_node: Element): TransitionConfig {
  return { duration: reduceMotion() ? 150 : 250, easing: cubicOut, css: (t) => `opacity:${t}` };
}

/** One digit rolling in (contentTransition(.numericText)); `down` counts down. */
export function roll(_node: Element, { down = false }: { down?: boolean } = {}): TransitionConfig {
  if (reduceMotion()) return { duration: 150, css: (t) => `opacity:${t}` };
  const dir = down ? -1 : 1;
  return {
    duration: tick.ms,
    easing: tick.ease,
    css: (t, u) => `opacity:${t};transform:translateY(${dir * u * 0.6}em)`,
  };
}
