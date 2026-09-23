import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The ziguri dev build loads http://localhost:5173/, so the port is fixed.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, strictPort: true },
  clearScreen: false,
});
