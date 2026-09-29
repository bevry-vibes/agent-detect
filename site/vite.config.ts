import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": new URL("./src", import.meta.url).pathname,
    },
  },
  server: {
    // `deno task spa` + `deno task dev` (wrangler) side by side: the SPA dev
    // server proxies the worker endpoints to wrangler on 8787.
    proxy: {
      "/index.json": "http://127.0.0.1:8787",
      "/registry.json": "http://127.0.0.1:8787",
      "/identify": "http://127.0.0.1:8787",
    },
  },
});
