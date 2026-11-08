<script lang="ts">
  // While editing a tall video: where phone apps put their own buttons and
  // words (the top and bottom bands), drawn faintly over the preview so what
  // matters stays clear of them (SafeAreaGuides on the Mac). Never exported.
  import type { Rect } from "../plan";
  let { safe, canvas, w, h }: { safe: Rect; canvas: { width: number; height: number }; w: number; h: number } = $props();
  const k = $derived(w / canvas.width);
  const r = $derived({ x: safe.x * k, y: safe.y * k, w: safe.w * k, h: safe.h * k });
</script>

<svg class="guides" width={w} height={h} viewBox="0 0 {w} {h}" aria-hidden="true" data-safe-guides>
  <path
    fill-rule="evenodd"
    fill="rgba(0, 0, 0, 0.16)"
    d="M0 0H{w}V{h}H0Z M{r.x + 6} {r.y}H{r.x + r.w - 6}Q{r.x + r.w} {r.y} {r.x + r.w} {r.y + 6}V{r.y + r.h - 6}Q{r.x + r.w} {r.y + r.h} {r.x + r.w - 6} {r.y + r.h}H{r.x + 6}Q{r.x} {r.y + r.h} {r.x} {r.y + r.h - 6}V{r.y + 6}Q{r.x} {r.y} {r.x + 6} {r.y}Z"
  />
  <rect x={r.x + 0.5} y={r.y + 0.5} width={r.w - 1} height={r.h - 1} rx="6" fill="none" stroke="rgba(255, 255, 255, 0.28)" stroke-dasharray="4 4" />
</svg>

<style>
  .guides {
    position: absolute;
    inset: 0;
    pointer-events: none;
  }
</style>
