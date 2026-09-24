import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

export default {
  // TypeScript and other preprocessing for <script lang="ts"> and <style>.
  preprocess: vitePreprocess(),
};
