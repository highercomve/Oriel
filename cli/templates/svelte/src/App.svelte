<script lang="ts">
  import { onMount } from "svelte";
  // Generated from the Zig `Commands` and `Events` (zig build types).
  import { invoke, listen, type Commands } from "./oriel";

  type AppInfo = Commands["app_info"]["result"];

  let name = $state("Oriel");
  let greeting = $state("");
  let count = $state(0);
  let info = $state<AppInfo | null>(null);
  let error = $state("");

  async function greet() {
    try {
      greeting = await invoke("greet", { name });
      error = "";
    } catch (err) {
      error = String(err);
    }
  }

  function submit(e: SubmitEvent) {
    e.preventDefault();
    greet();
  }

  onMount(() => {
    // Pushed from Zig by `events.emit(.greeted, ...)`.
    const off = listen("greeted", (e) => (count = e.count));
    greet();
    invoke("app_info").then((i) => (info = i));
    return off;
  });
</script>

<main>
  <h1>@@title@@</h1>
  <p class="tagline">Svelte + Vite, with Zig on the other side of invoke().</p>
  <form onsubmit={submit}>
    <input bind:value={name} placeholder="Your name" />
    <button type="submit">Greet</button>
  </form>
  <p class={error ? "greeting error" : "greeting"}>{error || greeting}</p>
  <p class="count">Greeted {count} {count === 1 ? "time" : "times"} (event from Zig)</p>
  {#if info}
    <footer>Zig {info.zig} · {info.mode}{info.dev ? " · dev server" : ""}</footer>
  {/if}
</main>
