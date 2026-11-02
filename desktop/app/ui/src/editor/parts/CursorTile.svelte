<script lang="ts">
  // One cursor style on paper, drawn by the same art the export uses.
  import type { CursorArt } from "../plan";
  let { art, selected, tag = false }: { art: CursorArt | null; selected: boolean; tag?: boolean } = $props();
  let canvas: HTMLCanvasElement;

  $effect(() => {
    if (!canvas || !art) return;
    canvas.width = art.width;
    canvas.height = art.height;
    // The art is premultiplied; ImageData is straight alpha.
    const d = new Uint8ClampedArray(art.rgba.length);
    for (let i = 0; i < d.length; i += 4) {
      const a = art.rgba[i + 3];
      const k = a ? 255 / a : 0;
      d[i] = art.rgba[i] * k;
      d[i + 1] = art.rgba[i + 1] * k;
      d[i + 2] = art.rgba[i + 2] * k;
      d[i + 3] = a;
    }
    canvas.getContext("2d")!.putImageData(new ImageData(d, art.width, art.height), 0, 0);
  });
</script>

<span class="tile" class:selected>
  <span class="paper">
    <canvas bind:this={canvas} style:width="{(art?.width ?? 0) / 2}px" style:height="{(art?.height ?? 0) / 2}px" style:margin-left={tag ? "3px" : "0"}></canvas>
  </span>
</span>

<style>
  .tile {
    display: inline-flex;
    padding: 2.5px;
    border-radius: 10px;
    box-shadow: inset 0 0 0 1.6px transparent;
    transition:
      box-shadow var(--dur-snappy) var(--ease-snappy),
      transform var(--dur-snappy) var(--ease-snappy);
  }
  .tile.selected {
    box-shadow: inset 0 0 0 1.6px var(--violet);
    transform: scale(1.04);
  }
  .paper {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    background: #e9e6df;
    display: grid;
    place-items: center;
    overflow: hidden;
  }
</style>
