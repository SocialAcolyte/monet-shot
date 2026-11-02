<script lang="ts">
  // A label, its value, and a small slider (SliderRow), tinted violet.
  let {
    label,
    value,
    min,
    max,
    format,
    onchange,
  }: { label: string; value: number; min: number; max: number; format: (v: number) => string; onchange: (v: number) => void } = $props();
  const fill = $derived(((value - min) / (max - min)) * 100);
</script>

<div class="row">
  <div class="head">
    <span class="label">{label}</span>
    <span class="value tabular">{format(value)}</span>
  </div>
  <input
    type="range"
    {min}
    {max}
    step={(max - min) / 1000}
    {value}
    style:--fill="{fill}%"
    oninput={(e) => onchange(+(e.currentTarget as HTMLInputElement).value)}
  />
</div>

<style>
  .row {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .head {
    display: flex;
    justify-content: space-between;
  }
  .label {
    font-size: 12px;
  }
  .value {
    font-size: 11.5px;
    font-weight: 500;
    color: var(--dim);
  }
  input {
    -webkit-appearance: none;
    appearance: none;
    width: 100%;
    height: 16px;
    margin: 0;
    background: transparent;
  }
  input::-webkit-slider-runnable-track {
    height: 4px;
    border-radius: 2px;
    background: linear-gradient(to right, var(--violet) var(--fill), var(--midnight) var(--fill));
  }
  input::-moz-range-track {
    height: 4px;
    border-radius: 2px;
    background: var(--midnight);
  }
  input::-moz-range-progress {
    height: 4px;
    border-radius: 2px;
    background: var(--violet);
  }
  input::-webkit-slider-thumb {
    -webkit-appearance: none;
    width: 14px;
    height: 14px;
    margin-top: -5px;
    border-radius: 50%;
    background: #f4f2ee;
    box-shadow: 0 0.5px 2px rgba(0, 0, 0, 0.5);
  }
  input::-moz-range-thumb {
    width: 14px;
    height: 14px;
    border: 0;
    border-radius: 50%;
    background: #f4f2ee;
    box-shadow: 0 0.5px 2px rgba(0, 0, 0, 0.5);
  }
</style>
