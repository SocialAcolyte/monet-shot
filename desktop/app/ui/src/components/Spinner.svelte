<script lang="ts">
  // A small indeterminate ring (ProgressView().controlSize(.small)).
  let { size = 14 }: { size?: number } = $props();
</script>

<svg class="spinner" width={size} height={size} viewBox="0 0 16 16" aria-label="Loading">
  <circle cx="8" cy="8" r="6.5" fill="none" stroke="currentColor" stroke-opacity="0.2" stroke-width="2" />
  <path d="M8 1.5 A6.5 6.5 0 0 1 14.5 8" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
</svg>

<style>
  .spinner {
    color: var(--dim);
    animation: spin 0.9s linear infinite;
    flex: none;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
