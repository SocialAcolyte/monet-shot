<script lang="ts">
  // A label and a mini switch (ToggleRow), violet when on.
  let { label, on, onchange }: { label: string; on: boolean; onchange: (v: boolean) => void } = $props();
</script>

<label class="row">
  <span>{label}</span>
  <button class="switch" class:on role="switch" aria-checked={on} aria-label={label} onclick={() => onchange(!on)}>
    <span class="knob"></span>
  </button>
</label>

<style>
  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 12px;
  }
  .switch {
    width: 26px;
    height: 15px;
    border-radius: 8px;
    background: var(--midnight);
    position: relative;
    transition: background var(--dur-snappy) var(--ease-snappy);
    flex: none;
  }
  .switch.on {
    background: var(--violet);
  }
  .knob {
    position: absolute;
    left: 1.5px;
    top: 1.5px;
    width: 12px;
    height: 12px;
    border-radius: 50%;
    background: #f4f2ee;
    box-shadow: 0 0.5px 1.5px rgba(0, 0, 0, 0.4);
    transition: transform var(--dur-snappy) var(--ease-snappy);
  }
  .on .knob {
    transform: translateX(11px);
  }
</style>
