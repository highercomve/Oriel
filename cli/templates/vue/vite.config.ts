import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

// The Oriel dev build loads http://localhost:5173/, so the port is fixed.
export default defineConfig({
  plugins: [vue()],
  server: { port: 5173, strictPort: true },
  clearScreen: false,
});
