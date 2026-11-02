<script lang="ts" generics="T">
  // A segmented control (.pickerStyle(.segmented)) in the charcoal palette.
  import type { Component } from "svelte";
  let {
    options,
    value,
    onchange,
    disabled = false,
    fit = false,
  }: {
    options: { value: T; label: string; icon?: Component<{ size?: number }> }[];
    value: T;
    onchange: (v: T) => void;
    disabled?: boolean;
    fit?: boolean;
  } = $props();
</script>

<div class="seg" class:fit class:disabled role="radiogroup">
  {#each options as o (o.label)}
    <button class:on={o.value === value} role="radio" aria-checked={o.value === value} {disabled} onclick={() => onchange(o.value)}>
      {#if o.icon}<o.icon size={12} />{/if}
      {o.label}
    </button>
  {/each}
</div>

<style>
  .seg {
    display: flex;
    padding: 2px;
    gap: 2px;
    border-radius: 7px;
    background: var(--midnight);
  }
  .seg.fit {
    display: inline-flex;
  }
  .disabled {
    opacity: 0.5;
  }
  button {
    flex: 1;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 5px;
    height: 20px;
    padding: 0 9px;
    border-radius: 5px;
    font-size: 11.5px;
    font-weight: 500;
    color: var(--dim);
    white-space: nowrap;
    transition:
      background var(--dur-snappy) var(--ease-snappy),
      color var(--dur-snappy) var(--ease-snappy);
  }
  button.on {
    background: #5b5f63;
    color: var(--moon-white);
    box-shadow: 0 0.5px 1.5px rgba(0, 0, 0, 0.35);
  }
</style>
