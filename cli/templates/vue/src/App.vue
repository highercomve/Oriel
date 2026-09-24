<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
// Generated from the Zig `Commands` and `Events` (zig build types).
import { invoke, listen, type Commands } from "./oriel";

type AppInfo = Commands["app_info"]["result"];

const name = ref("Oriel");
const greeting = ref("");
const count = ref(0);
const info = ref<AppInfo | null>(null);
const error = ref("");

async function greet() {
  try {
    greeting.value = await invoke("greet", { name: name.value });
    error.value = "";
  } catch (err) {
    error.value = String(err);
  }
}

// Pushed from Zig by `events.emit(.greeted, ...)`.
const off = listen("greeted", (e) => (count.value = e.count));
onUnmounted(off);

onMounted(async () => {
  greet();
  info.value = await invoke("app_info");
});
</script>

<template>
  <main>
    <h1>@@title@@</h1>
    <p class="tagline">Vue + Vite, with Zig on the other side of invoke().</p>
    <form @submit.prevent="greet">
      <input v-model="name" placeholder="Your name" />
      <button type="submit">Greet</button>
    </form>
    <p :class="error ? 'greeting error' : 'greeting'">{{ error || greeting }}</p>
    <p class="count">Greeted {{ count }} {{ count === 1 ? "time" : "times" }} (event from Zig)</p>
    <footer v-if="info">Zig {{ info.zig }} · {{ info.mode }}{{ info.dev ? " · dev server" : "" }}</footer>
  </main>
</template>
