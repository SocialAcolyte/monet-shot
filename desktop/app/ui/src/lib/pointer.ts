/** Keeps a drag's pointer events on `el`. A pointer that can't be captured
 *  (already released, or a synthetic one from a dev check) still drags,
 *  just without capture. */
export function capture(el: Element, pointerId: number) {
  try {
    el.setPointerCapture(pointerId);
  } catch {
    // not capturable: the element's own listeners still see the moves
  }
}
