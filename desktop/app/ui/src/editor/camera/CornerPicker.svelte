<script lang="ts">
  // Four dots in a little square: which corner the camera bubble sits in.
  type Corner = "topLeft" | "topRight" | "bottomLeft" | "bottomRight";
  let { corner, onchange }: { corner: string; onchange: (c: Corner) => void } = $props();
  const corners: Corner[] = ["topLeft", "topRight", "bottomLeft", "bottomRight"];
</script>

<div class="grid" title="Corner" role="radiogroup" aria-label="Corner">
  {#each corners as c (c)}
    <button class:on={corner === c} role="radio" aria-checked={corner === c} aria-label={c} onclick={() => onchange(c)}></button>
  {/each}
</div>

<style>
  .grid {
    display: grid;
    grid-template-columns: 12px 12px;
    gap: 3px;
    padding: 4px;
    border-radius: 6px;
    background: var(--midnight);
    flex: none;
  }
  button {
    width: 12px;
    height: 8px;
    border-radius: 2px;
    background: var(--faint);
    opacity: 0.5;
  }
  button.on {
    background: var(--violet);
    opacity: 1;
  }
</style>
