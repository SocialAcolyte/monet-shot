<script lang="ts">
  let { text }: { text: string } = $props();
</script>

<p>{text}</p>

<style>
  p {
    margin: 0;
    font-size: 11.5px;
    line-height: 1.35;
    color: var(--dim);
  }
</style>
