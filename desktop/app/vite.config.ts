import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { fileURLToPath } from "node:url";

// MONETSHOT_DEV_FS=<dir> lets the browser mock read recordings outside the repo.
// Tauri serves the dev server on a fixed port and loads ui/dist when bundled.
export default defineConfig(({ command }) => ({
  root: "ui",
  plugins: [svelte()],
  // The repo's root, for dev pages and the browser mock (they read /@fs paths).
  // (Dev server only: a bundle doesn't carry the build machine's paths.)
  define: {
    // As a /@fs path: on Windows D:\a\repo\ becomes /D:/a/repo.
    __MONETSHOT_REPO__: JSON.stringify(command === "serve" ? fileURLToPath(new URL("../..", import.meta.url)).replace(/\\/g, "/").replace(/\/$/, "").replace(/^(?=[A-Za-z]:)/, "/") : ""),
  },
  resolve: {
    alias: { "monetshot-core-wasm": fileURLToPath(new URL("../crates/core-wasm/pkg/monetshot_core_wasm.js", import.meta.url)) },
  },
  clearScreen: false,
  server: { port: 5183, strictPort: true, fs: { allow: ["../../..", ...(process.env.MONETSHOT_DEV_FS ? [process.env.MONETSHOT_DEV_FS] : [])] } },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    // WebKitGTK 2.40+ (Linux) and WebView2 (Windows) handle es2022 (top-level await).
    target: "es2022",
  },
}));
