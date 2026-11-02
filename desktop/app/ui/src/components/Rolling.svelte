<script lang="ts">
  // Text whose characters roll as they change (contentTransition(.numericText)):
  // only the digits that change move.
  import { roll } from "../lib/motion";
  let { text, down = false }: { text: string; down?: boolean } = $props();
  const chars = $derived([...text]);
</script>

<span class="rolling tabular">
  {#each chars as ch, i (`${chars.length - i}`)}
    <span class="slot">
      {#key ch}
        <span class="ch" in:roll={{ down }}>{ch}</span>
      {/key}
    </span>
  {/each}
</span>

<style>
  .rolling {
    display: inline-flex;
    overflow: hidden;
  }
  .slot {
    display: inline-grid;
  }
  .ch {
    grid-area: 1 / 1;
  }
</style>
