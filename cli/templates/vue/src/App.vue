<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
// Generated from the Zig `Commands` and `Events` (zig build types).
import { invoke, listen, deepLink, type Commands } from "./oriel";

type AppInfo = Commands["app_info"]["result"];

const name = ref("Oriel");
const greeting = ref("");
const count = ref(0);
const info = ref<AppInfo | null>(null);
const error = ref("");
const openedLink = ref<string | null>(null);

async function greet() {
  try {
    greeting.value = await invoke("greet", { name: name.value });
    error.value = "";
  } catch (err) {
    error.value = String(err);
  }
}

// Pushed from Zig by `events.emit(.greeted, ...)`.
const offGreeted = listen("greeted", (e) => (count.value = e.count));
const offLink = listen("deep-link", (e) => (openedLink.value = e.url));
onUnmounted(() => {
  offGreeted();
  offLink();
});

onMounted(async () => {
  deepLink?.current().then((url) => { if (url) openedLink.value = url; });
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
    <p v-if="openedLink" class="opened-link">Opened via link: {{ openedLink }}</p>
    <footer v-if="info">Zig {{ info.zig }} · {{ info.mode }}{{ info.dev ? " · dev server" : "" }}</footer>
  </main>
</template>
