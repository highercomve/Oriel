import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// The Oriel dev build loads http://localhost:5173/, so the port is fixed.
export default defineConfig({
  plugins: [svelte()],
  server: { port: 5173, strictPort: true },
  clearScreen: false,
});
