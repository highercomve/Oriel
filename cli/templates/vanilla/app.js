// `window.oriel` is injected by Oriel: invoke(command, args) calls a function
// in the Zig `Commands` struct, listen(event, callback) receives `Events`.
const { invoke, listen } = window.oriel;

const $ = (id) => document.getElementById(id);

async function greet() {
  const out = $("greeting");
  try {
    out.textContent = await invoke("greet", { name: $("name").value });
    out.className = "greeting";
  } catch (err) {
    out.textContent = String(err);
    out.className = "greeting error";
  }
}

// Pushed from Zig by `events.emit(.greeted, ...)`.
listen("greeted", ({ count }) => {
  $("count").textContent = `Greeted ${count} ${count === 1 ? "time" : "times"} (event from Zig)`;
});

const showLink = (url) => {
  const el = $("opened-link");
  if (el && url) {
    el.textContent = `Opened via link: ${url}`;
    el.style.display = "";
  }
};
listen("deep-link", ({ url }) => showLink(url));
window.oriel.deepLink?.current?.().then((url) => showLink(url));

$("greet-form").addEventListener("submit", (e) => {
  e.preventDefault();
  greet();
});

greet();
invoke("app_info", null).then((info) => {
  $("info").textContent = `Zig ${info.zig} · ${info.mode}`;
});
