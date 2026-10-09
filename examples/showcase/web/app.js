const { invoke, listen, window: win } = window.oriel;
const $ = (id) => document.getElementById(id);
const second = new URLSearchParams(location.search).has("second");
let windows = 0;

function setResult(el, text, kind) {
  $(el).textContent = text;
  $(el).className = "result" + (kind ? " " + kind : "");
}
async function show(el, fn) {
  try { setResult(el, await fn(), "ok"); } catch (e) { setResult(el, "Error: " + (e.message || e), "err"); }
}

let info = null;
(async () => {
  info = await invoke("info");
  const n = second ? 0 : await invoke("launches");
  $("info").textContent = `${info.os} ${info.arch}${n ? ` · launch #${n}` : ""} · ${win.current().label}`;
  $("launches").textContent = n ? String(n) : "—";
  $("dev-data").textContent = info.data_dir;
  $("dev-desktop").textContent = [info.tray && "tray", info.menu && "menu", info.hotkeys && (info.android ? "in-app shortcuts" : "system-wide hotkeys")].filter(Boolean).join(", ") || "—";
  setupAnywhere();
  setupKeys();
  setupLinks();
})().catch((e) => { $("info").textContent = String(e.message || e); });

// Tabs: the hash picks the section, so every switch is a history entry and
// Android's back button (WebView.goBack) returns to the previous tab.
// The new panel slides in from the side of the tab it came from.
const tabs = [...document.querySelectorAll("#tabs a")];
let current = -1;
function route() {
  const id = location.hash.slice(1);
  const index = tabs.findIndex((a) => a.hash === "#" + id);
  if (index < 0) return location.replace("#dictate");
  for (const a of tabs) a.setAttribute("aria-selected", String(a.hash === "#" + id));
  for (const s of document.querySelectorAll("main > section")) {
    s.classList.remove("from-left", "from-right");
    s.classList.toggle("active", s.id === id);
    if (s.id === id && current >= 0 && index !== current) {
      void s.offsetWidth; // restart the animation
      s.classList.add(index > current ? "from-right" : "from-left");
    }
  }
  current = index;
  if (id === "chat" && !matchMedia("(pointer: coarse)").matches) $("chat-input").focus();
  if (id === "speak" && !matchMedia("(pointer: coarse)").matches) $("tts-text").focus();
  if (id === "notes") {
    loadNotes();
    // A keyboard and mouse: type right away (a touch screen would pop the keyboard up).
    if (!matchMedia("(pointer: coarse)").matches) $("note-input").focus();
  }
}
addEventListener("hashchange", route);
route();

// ---------------------------------------------------------------------------
// Notes: SQLite in Zig; deep links add notes (the `notes` event).

function renderNotes(list) {
  const ul = $("note-list");
  ul.innerHTML = "";
  if (!list.length) ul.innerHTML = '<li class="empty">No notes yet.</li>';
  for (const n of list) {
    const li = document.createElement("li");
    li.innerHTML = "<div><p></p><small></small></div>";
    li.querySelector("p").textContent = n.text;
    li.querySelector("small").textContent = n.created_at;
    li.append(readButton(n.text, false, (m) => setResult("note-out", m, "err")));
    const del = document.createElement("button");
    del.className = "btn ghost icon";
    del.setAttribute("aria-label", "Delete the note");
    del.innerHTML = '<svg><use href="#i-trash"/></svg>';
    del.addEventListener("click", async () => renderNotes(await invoke("notes_delete", { id: n.id })));
    li.append(del);
    ul.append(li);
  }
}
async function loadNotes() {
  try { renderNotes(await invoke("notes_list")); } catch (e) { $("note-list").textContent = "Error: " + (e.message || e); }
}
$("note-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = $("note-input").value;
  if (!text.trim()) return;
  renderNotes(await invoke("notes_add", { text }));
  $("note-input").value = "";
});
$("note-dictation").addEventListener("click", async () => {
  if (dict.lastText) renderNotes(await invoke("notes_add", { text: dict.lastText }));
});
listen("notes", renderNotes);
listen("link", (l) => { setResult("link-out", `✓ Received ${l.url}`, "ok"); location.hash = "#notes"; });
function setupLinks() {
  const url = "oriel-showcase://note/Hello%20from%20a%20link";
  $("link-cmd").textContent = info.android ? `adb shell am start -d "${url}"`
    : info.os === "macos" ? `open "${url}"` : info.os === "windows" ? `start "" "${url}"`
    : info.os === "ios" ? `xcrun simctl openurl booted "${url}"` : `xdg-open "${url}"`;
  $("link-note").hidden = info.os !== "windows";
}

// ---------------------------------------------------------------------------
// Files: the platform's pickers.

$("file-open").addEventListener("click", async () => {
  try {
    const f = await invoke("open_file");
    if (!f) return setResult("file-info", "Cancelled");
    setResult("file-info", `✓ ${f.path.split(/[\\/]/).pop()} · ${f.size.toLocaleString()} bytes${f.binary ? " · binary, no preview" : ""}`, "ok");
    $("file-preview").hidden = !f.preview;
    $("file-preview").textContent = f.preview;
  } catch (e) { setResult("file-info", "Error: " + (e.message || e), "err"); }
});
$("file-save").addEventListener("click", () => show("file-out", async () =>
  (await invoke("save_file", { text: $("file-text").value })) ? "✓ Saved" : "Cancelled"));

// ---------------------------------------------------------------------------
// System: clipboard, notifications, dictate anywhere, keyboard shortcuts.

$("copy").addEventListener("click", () => show("sys-out", async () => { await invoke("copy", { text: $("note-input").value || $("echo-input").value }); return "✓ Copied to the clipboard"; }));
$("paste").addEventListener("click", () => show("sys-out", async () => `Clipboard: ${(await invoke("paste")) || "(empty)"}`));
$("notify").addEventListener("click", () => show("sys-out", async () => {
  if ((await window.oriel.permissions.request("notifications")) !== "granted") throw new Error("notifications aren't allowed");
  await invoke("notify", { text: "Hello from Zig" });
  return "✓ Notification sent: click it or a button";
}));
listen("notification:action", (n) => setResult("sys-out", `✓ Notification ${n.id}: ${n.action ?? "clicked"}`, "ok"));

function setupAnywhere() {
  if (!info.anywhere) return;
  $("anywhere-card").hidden = false;
  $("anywhere-hint").textContent = info.android
    ? "Talk into any app: the Quick Settings tile, the Oriel keyboard's mic, the headset button or this button start it; the text goes into the focused field."
    : `Talk into any app: press ${info.hotkey.toUpperCase()} anywhere (or use the tray icon), talk, press it again: the text is typed where the cursor is.`;
}
$("anywhere-toggle").addEventListener("click", async () => {
  await invoke("anywhere_configure", options());
  await invoke("anywhere_toggle");
});
listen("anywhere", (a) => {
  const label = { listening: "Listening… press again to insert", transcribing: "Transcribing…", inserted: `✓ Typed: ${a.text}`,
    copied: `✓ Copied to the clipboard: ${a.text}`, nothing: "Nothing heard", error: why(a.text) }[a.state] || a.state;
  setResult("anywhere-out", label, a.state === "error" ? "err" : a.state === "inserted" || a.state === "copied" ? "ok" : "");
  $("anywhere-toggle").querySelector("span").textContent = a.state === "listening" ? "Stop and insert" : "Start";
});

function setupKeys() {
  const keys = [];
  if (info.hotkeys && !info.android) keys.push([info.hotkey.toUpperCase(), "Dictate into any app (system-wide)"]);
  if (info.android || info.menu) keys.push(["CTRL+SHIFT+D", "Start or stop dictation"], ["CTRL+1 … 7", "Switch tabs"]);
  keys.push(["ENTER", "Send a chat message (Shift+Enter: new line)"]);
  if (info.android) keys.push(["META+/", "List this app's shortcuts (Android)"]);
  if (!keys.length) keys.push(["—", "No keyboard shortcuts on this platform"]);
  $("keys").innerHTML = keys.map(([k, d]) => `<li><kbd>${k}</kbd><span>${d}</span></li>`).join("");
}

// ---------------------------------------------------------------------------
// App: windows, IPC, events.

async function echo() {
  const text = $("echo-input").value;
  try {
    const back = await invoke("echo", { text });
    setResult("echo-out", back === text ? `✓ Round trip: ${back}` : `Mismatch: ${back}`, back === text ? "ok" : "err");
  } catch (e) { setResult("echo-out", "Error: " + (e.message || e), "err"); }
}
$("echo-form").addEventListener("submit", (e) => { e.preventDefault(); echo(); });

const dots = [...document.querySelectorAll(".ticks i")];
listen("tick", (n) => {
  dots.forEach((d, i) => d.classList.toggle("on", i < n));
  setResult("tick-out", `tick ${n} of 5`);
});
$("ticks").addEventListener("click", () => {
  dots.forEach((d) => d.classList.remove("on"));
  show("tick-out", async () => { await invoke("ticks"); return "✓ All five arrived"; });
});

async function openWindow() {
  windows += 1;
  await invoke("open_window", { n: windows });
  setResult("windows-out", `✓ Opened window ${windows}`, "ok");
}
$("open").addEventListener("click", () => openWindow().catch((e) => setResult("windows-out", "Error: " + (e.message || e), "err")));
listen("window:closed", (e) => setResult("windows-out", `Closed ${e.label}`));

// Device
const p = window.oriel.platform;
$("platform").textContent = p ? `${p.os} · ${p.arch}` : "unknown";
function size() { $("size").textContent = `${innerWidth} × ${innerHeight} px`; }
addEventListener("resize", size);
size();

// Context menu
const menu = $("menu");
addEventListener("contextmenu", (e) => {
  e.preventDefault();
  menu.hidden = false;
  menu.style.left = Math.min(e.clientX, innerWidth - menu.offsetWidth - 4) + "px";
  menu.style.top = Math.min(e.clientY, innerHeight - menu.offsetHeight - 4) + "px";
});
addEventListener("click", (e) => {
  if (menu.hidden) return;
  const item = e.target.closest("#menu li");
  menu.hidden = true;
  if (!item) return;
  if (item.dataset.action === "echo") { location.hash = "#app"; echo(); }
  if (item.dataset.action === "open") openWindow();
  if (item.dataset.action === "close") win.current().close();
});
addEventListener("keydown", (e) => { if (e.key === "Escape") menu.hidden = true; });

// ---------------------------------------------------------------------------
// Dictate: oriel.dictation. Whisper (any platform, offline, the CPU or the
// GPU) or the system's recognizer (Android); Auto picks for the device.

const dict = { status: null, engine: "whisper", model: null, lang: "auto", backend: "auto", recording: false, busy: false, live: null };

function segmented(el, onPick) {
  el.addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b || b.disabled) return;
    for (const x of el.querySelectorAll("button")) x.setAttribute("aria-checked", String(x === b));
    onPick(b.dataset.value);
  });
}
segmented($("dict-engine"), (v) => { dict.engine = v; dictRender(); });
segmented($("dict-lang"), (v) => { dict.lang = v; dict.usedServers = false; }); // another language may have its model
segmented($("dict-model"), (v) => { dict.model = v; dictRender(); });
segmented($("dict-proc"), (v) => { dict.backend = v; dictRender(); });

function setState(text) { $("dict-state").textContent = text; }
const engineNow = () => (dict.engine === "auto" ? dict.status?.auto_engine || "whisper" : dict.engine);
// "on-device" until a phrase says it went to Apple's servers (no on-device
// model for the language).
const systemName = () => (dict.status?.system_on_device && !dict.usedServers ? "System · on-device" : "System speech");

async function dictRefresh() {
  if (!dict.status) loadSources();
  const st = await invoke("dictation_status");
  dict.status = st;
  $("dev-backend").textContent = st.gpu ? `${st.backend} (${st.gpu})` : "CPU";
  $("dev-speech").textContent = st.system ? (st.system_on_device ? "On-device" : "Installed (may use the network)") : "None";
  // The system recognizer, where there is one (Android).
  $("dict-engine-field").hidden = !st.system;
  $("dict-system-sub").textContent = st.system_on_device ? "on-device, fast" : "may use the network";
  const current = st.models.filter((m) => !m.legacy);
  if (!dict.model || !current.some((m) => m.name === dict.model)) dict.model = ([...current].reverse().find((m) => m.present) || current[1]).name;
  const seg = $("dict-model");
  seg.innerHTML = "";
  for (const m of current) {
    const b = document.createElement("button");
    b.dataset.value = m.name;
    b.setAttribute("aria-checked", String(m.name === dict.model));
    b.innerHTML = `${m.name}<small>${m.present ? '<span class="have">✓ ready</span>' : `${m.mb} MB`}</small>`;
    seg.append(b);
  }
  // Files from earlier versions: only to delete them.
  const legacy = st.models.filter((m) => m.legacy && m.present);
  const box = $("dict-legacy");
  box.hidden = legacy.length === 0;
  box.innerHTML = legacy.length ? '<span class="label">Older models on this device</span>' : "";
  for (const m of legacy) {
    const row = document.createElement("div");
    row.className = "have-row";
    row.innerHTML = `<span>${m.name} · ${m.mb} MB</span>`;
    const del = document.createElement("button");
    del.className = "btn danger";
    del.innerHTML = '<svg><use href="#i-trash"/></svg><span>Delete</span>';
    del.addEventListener("click", () => armDelete(del, m.name));
    row.append(del);
    box.append(row);
  }
  dictRender();
}

function dictRender() {
  const st = dict.status;
  if (!st) return;
  const whisper = engineNow() === "whisper";
  const chipEl = $("dict-backend");
  if (whisper) {
    chipEl.className = "chip status " + (st.gpu ? "gpu" : "cpu");
    chipEl.querySelector("b").textContent = st.gpu ? `Whisper · ${st.backend} · ${st.gpu}` : "Whisper · CPU";
  } else {
    chipEl.className = "chip status gpu";
    chipEl.querySelector("b").textContent = systemName();
  }
  for (const b of $("dict-engine").querySelectorAll("button")) b.setAttribute("aria-checked", String(b.dataset.value === dict.engine));
  $("dict-whisper").hidden = !whisper;
  $("dict-whisper-opts").hidden = !whisper;
  $("dict-system-note").hidden = whisper;
  for (const b of $("dict-model").querySelectorAll("button")) b.setAttribute("aria-checked", String(b.dataset.value === dict.model));
  const m = st.models.find((x) => x.name === dict.model);
  $("dict-get").hidden = m.present;
  $("dict-have").hidden = !m.present;
  // Live text drafts with the next smaller model on the device.
  const current = st.models.filter((x) => !x.legacy);
  const smaller = current.slice(0, current.findIndex((x) => x.name === m.name));
  const noDraft = smaller.length > 0 && !smaller.some((x) => x.present);
  $("dict-have-text").textContent = `${m.mb} MB on this device` +
    (noDraft ? ` · download ${smaller[smaller.length - 1].name} too for faster live text` : "");
  // Processor: Auto uses what Compare measured, else the GPU on desktops
  // and the CPU on phones.
  for (const b of $("dict-proc").querySelectorAll("button")) {
    b.setAttribute("aria-checked", String(b.dataset.value === dict.backend));
    if (b.dataset.value === "gpu") b.disabled = !st.gpu;
  }
  $("dict-proc-note").textContent = !st.gpu ? "No GPU backend here: whisper runs on the CPU."
    : m.faster ? `Auto: the ${m.faster.toUpperCase()}, measured faster for ${m.name} on this device.`
    : "Auto: the GPU on desktops, the CPU on phones, until Compare measures it.";
  $("dict-delete").disabled = dict.busy || dict.recording;
  $("dict-download").disabled = !!st.downloading;
  $("dict-file").disabled = dict.busy || dict.recording;
  $("dict-missing").textContent = `Or copy ${m.file} to ${st.models_dir}${info?.os === "windows" ? "\\" : "/"}`;
  const ready = !whisper || m.present;
  $("dict-rec").disabled = dict.busy || (!ready && !dict.recording);
  if (!dict.recording && !dict.busy) setState(ready ? "Tap to talk" : `Download ${m.name} (${m.mb} MB) to start`);
}

const options = () => ({ engine: dict.engine, model: dict.model, language: dict.lang, vad: $("dict-vad").checked, backend: dict.backend,
  source: $("dict-source").value || null });

// Where whisper listens: microphones, and system audio on the desktop.
async function loadSources() {
  try {
    const list = await invoke("dictation_sources");
    const sel = $("dict-source");
    for (const src of list) {
      const o = document.createElement("option");
      o.value = src.name;
      o.textContent = src.monitor ? `System audio: ${src.description}` : src.description;
      sel.append(o);
    }
    $("dict-source-field").hidden = list.length < 2;
  } catch { /* no sources: the default microphone */ }
}

// Delete: a second tap within 3 s confirms.
const armed = new Map();
async function armDelete(btn, name) {
  const label = btn.querySelector("span");
  if (!armed.has(btn)) {
    btn.classList.add("confirm");
    label.textContent = "Tap to confirm";
    armed.set(btn, setTimeout(() => { armed.delete(btn); btn.classList.remove("confirm"); label.textContent = "Delete"; }, 3000));
    return;
  }
  clearTimeout(armed.get(btn));
  armed.delete(btn);
  btn.disabled = true;
  let failed = null;
  try {
    await invoke("dictation_delete", { model: name });
  } catch (e) {
    failed = String(e.message || e);
  }
  await dictRefresh();
  // After the refresh, which resets the status line.
  if (failed) setState(`Couldn't delete ${name}: ${failed}`);
}
$("dict-delete").addEventListener("click", () => armDelete($("dict-delete"), dict.model));

$("dict-download").addEventListener("click", async () => {
  const name = dict.model;
  $("dict-download").disabled = true;
  $("dict-get").querySelector(".progress").hidden = false;
  $("dict-progress").style.width = "0";
  try {
    await invoke("dictation_download", { model: name });
  } catch (e) {
    setState(`Download failed: ${e.message || e}`);
  }
  $("dict-get").querySelector(".progress").hidden = true;
  await dictRefresh();
});
listen("dictation:download", (p) => {
  $("dict-progress").style.width = `${Math.round((100 * p.done_mb) / Math.max(1, p.total_mb))}%`;
  setState(`Downloading ${p.model}: ${p.done_mb} of ${p.total_mb} MB`);
});
listen("dictation:level", (p) => {
  $("dict-rec").style.setProperty("--level", p.level.toFixed(2));
  $("dict-time").textContent = `${p.seconds.toFixed(1)} s`;
});

function busy(on) {
  dict.busy = on;
  $("dict-rec").classList.toggle("busy", on);
  $("dict-rec").disabled = on;
}

const friendly = {
  NothingRecorded: "Nothing recorded yet: record first.",
  Recording: "Stop recording first.",
  ModelNotFound: "That model isn't on the device.",
  NoModel: "Download a model first.",
  CpuUnsupported: "This CPU lacks the ARM extensions this build needs (dotprod).",
  EngineUnavailable: "No system speech recognizer on this device.",
  RecognizerUnavailable: "The system recognizer didn't start.",
  UnsupportedWav: "Only PCM or float WAV files: convert it first.",
  NotWav: "That isn't a WAV file.",
  LanguageUnavailable: "The system recognizer doesn't have this language offline.",
  LanguageNotSupported: "The system recognizer doesn't support this language.",
  LanguageDownloading: "Android is downloading this language for offline recognition: try again in a minute.",
  InsufficientPermissions: "The microphone isn't allowed.",
  Generating: "Still answering: wait or press Stop.",
  PromptTooLong: "That message is too long for the model's context.",
  ContextFailed: "Not enough memory for the model's context.",
  Cancelled: "Stopped.",
  UnknownModel: "Pick a model first.",
  // oriel.tts
  NoVoice: "No voice for this language on the device: download one on the Speak tab.",
  UnknownVoice: "Pick a voice first.",
  EspeakDataMissing: "The phoneme data (espeak-ng-data) is missing: reinstall the app.",
  VoiceFailed: "That voice file didn't load: delete it and download it again.",
  LanguageFailed: "The phonemizer doesn't know this language.",
  ModelLoadFailed: "The voice model didn't load (not enough memory, or a damaged file).",
  SynthesisFailed: "Nothing in that text could be read aloud.",
  ChecksumMismatch: "The download was damaged: try again.",
  AlreadyDownloading: "Another download is running: wait for it.",
  Downloading: "It's still downloading.",
  Speaking: "Stop speaking first.",
};
const why = (e) => { const n = String(e?.message || e); return friendly[n] || `Error: ${n}`; };
// Speech errors: NoModel is the voice model here.
const speakWhy = (e) => (String(e?.message || e) === "NoModel" ? "Download the voice model on the Speak tab first." : why(e));

function resetRec() {
  const btn = $("dict-rec");
  dict.recording = false;
  btn.classList.remove("recording");
  btn.style.setProperty("--level", 0);
  btn.setAttribute("aria-label", "Start recording");
}

async function stopRec() {
  resetRec();
  busy(true);
  setState("Finishing the last phrase…");
  try {
    addTranscript(await invoke("dictation_stop"));
    setState("Tap to talk");
  } catch (e) {
    dict.live?.card.remove();
    dict.live = null;
    setState(why(e));
  }
  busy(false);
  dictRender();
}

$("dict-rec").addEventListener("click", async () => {
  if (dict.recording) return stopRec();
  const btn = $("dict-rec");
  try {
    if ((await window.oriel.permissions.request("microphone")) !== "granted") return setState("The microphone isn't allowed");
    busy(true);
    setState(engineNow() === "whisper" ? `Loading ${dict.model}…` : "Starting the recognizer…");
    invoke("anywhere_configure", options()).catch(() => {});
    const s = await invoke("dictation_start", options());
    busy(false);
    dict.recording = true;
    liveCard();
    btn.classList.add("recording");
    btn.setAttribute("aria-label", "Stop and transcribe");
    $("dict-time").textContent = "0.0 s";
    const what = s.engine === "system" ? systemName() : `${s.model}${s.draft ? ` (drafts: ${s.draft})` : ""} on ${s.backend}`;
    setState(s.load_ms ? `${what} · loaded in ${s.load_ms} ms · listening` : `${what} · listening`);
  } catch (e) {
    resetRec();
    busy(false);
    dict.live?.card.remove();
    dict.live = null;
    setState(why(e));
  }
  dictRender();
});
listen("dictation:error", (e) => setState(why(e.message)));
// The system recognizer stopped on its own (an error): collect what it heard.
listen("dictation:ended", () => { if (dict.recording) stopRec(); });

function chip(text, cls) {
  const c = document.createElement("span");
  c.className = "chip" + (cls ? " " + cls : "");
  c.textContent = text;
  return c;
}

// While recording: finished phrases, then the one being spoken (lighter).
function liveCard() {
  const card = document.createElement("div");
  card.className = "card transcript live";
  card.innerHTML = '<p><span class="final"></span> <span class="partial"></span><span class="caret"></span></p><div class="chips"><span class="chip live-chip"><i></i>Live</span><span class="chip meta"></span></div>';
  // Only the newest recording can be compared (the app keeps one).
  for (const b of document.querySelectorAll(".transcript .chips .btn")) b.remove();
  $("dict-out").prepend(card);
  dict.live = { card };
}
listen("dictation:partial", (p) => {
  if (!dict.live) return;
  dict.live.card.querySelector(".partial").textContent = p.text;
});
listen("dictation:final", (f) => {
  if (f.on_device === false) dict.usedServers = true;
  if (!dict.live) return;
  const el = dict.live.card.querySelector(".final");
  el.textContent = (el.textContent ? el.textContent + " " : "") + f.text;
  dict.live.card.querySelector(".meta").textContent = f.transcribe_ms
    ? `${f.backend} · ${f.audio_s.toFixed(1)} s phrase in ${f.transcribe_ms} ms` : f.backend;
});

function addTranscript(r) {
  const card = dict.live?.card || document.createElement("div");
  dict.live = null;
  card.className = "card transcript";
  card.innerHTML = "";
  card.dataset.model = r.model;
  if (r.text) { dict.lastText = r.text; $("note-dictation").hidden = false; }
  const text = document.createElement("p");
  text.textContent = r.text || "Nothing heard";
  if (!r.text) text.className = "empty";
  const chips = document.createElement("div");
  chips.className = "chips";
  if (r.engine === "system") {
    chips.append(chip(systemName(), "gpu"), chip(`${r.audio_s.toFixed(1)} s`), chip(`${r.updates} updates`));
  } else {
    chips.append(
      chip(r.backend, r.backend !== "CPU" ? "gpu" : "cpu"),
      chip(r.draft ? `${r.model} · drafts by ${r.draft}` : r.model),
      chip(`${r.audio_s.toFixed(1)} s`),
      chip(`${r.updates} updates · ~${r.mean_ms} ms each`),
    );
    if (dict.status?.gpu) {
      const cmp = document.createElement("button");
      cmp.className = "btn ghost";
      cmp.innerHTML = '<svg><use href="#i-scale"/></svg><span>Compare</span>';
      cmp.title = "Time the recording on the GPU and on the CPU; Auto then uses the faster";
      cmp.addEventListener("click", () => compare(card, cmp));
      chips.append(cmp);
    }
  }
  card.append(text, chips);
  if (!card.isConnected) $("dict-out").prepend(card);
}

// Transcribe a file: a WAV picked from the device, with the chosen model.
$("dict-file").addEventListener("click", async () => {
  if (!dict.status) await dictRefresh();
  busy(true);
  setResult("file-transcript", "Pick a WAV file…");
  try {
    const t = await invoke("dictation_file", { ...options(), engine: "whisper" });
    if (t) {
      setResult("file-transcript", `✓ Transcribed ${t.audio_s.toFixed(1)} s in ${(t.transcribe_ms / 1000).toFixed(1)} s: see the Dictate tab`, "ok");
      const card = document.createElement("div");
      card.className = "card transcript";
      const p = document.createElement("p");
      p.textContent = t.text.trim() || "Nothing heard";
      const chips = document.createElement("div");
      chips.className = "chips";
      chips.append(chip("File"), chip(t.backend, t.backend !== "CPU" ? "gpu" : "cpu"), chip(t.model), chip(`${t.audio_s.toFixed(1)} s`),
        chip(`${(t.audio_s / Math.max(t.transcribe_ms / 1000, 0.001)).toFixed(1)}× real time`));
      card.append(p, chips);
      $("dict-out").prepend(card);
    } else setResult("file-transcript", "Cancelled");
  } catch (e) {
    setResult("file-transcript", why(e), "err");
  }
  busy(false);
  dictRender();
});

// Compare: rows for GPU and CPU up front; "dictation:compare" fills each as it ends.
let compareBox = null;
function compareRow(box, cls, ms) {
  const row = box.querySelector(`.bar.${cls}`);
  row.classList.remove("pending");
  row.dataset.ms = ms;
  row.querySelector("b").textContent = `${(ms / 1000).toFixed(2)} s`;
  const rows = [...box.querySelectorAll(".bar[data-ms]")];
  const max = Math.max(...rows.map((r) => +r.dataset.ms));
  requestAnimationFrame(() => { for (const r of rows) r.querySelector(".fill").style.width = `${(100 * +r.dataset.ms) / max}%`; });
}
listen("dictation:compare", (p) => { if (compareBox) compareRow(compareBox, p.backend.toLowerCase(), p.transcribe_ms); });

async function compare(card, btn) {
  btn.disabled = true;
  busy(true);
  setState("Comparing: GPU, then CPU…");
  card.querySelector(".compare")?.remove();
  const box = document.createElement("div");
  box.className = "compare";
  box.innerHTML = "<h3>GPU vs CPU, same recording</h3>";
  for (const [cls, name] of [["gpu", "GPU"], ["cpu", "CPU"]]) {
    const row = document.createElement("div");
    row.className = `bar ${cls} pending`;
    row.innerHTML = `<span>${name}</span><div class="track"><div class="fill"></div></div><b>…</b>`;
    box.append(row);
  }
  const note = document.createElement("p");
  note.className = "alt";
  note.textContent = "Running on up to 8 s of the recording…";
  box.append(note);
  card.append(box);
  compareBox = box;
  const model = card.dataset.model || dict.model;
  try {
    const c = await invoke("dictation_compare", { ...options(), engine: "whisper", model });
    if (c.gpu) compareRow(box, "gpu", c.gpu.transcribe_ms); else box.querySelector(".bar.gpu").remove();
    compareRow(box, "cpu", c.cpu.transcribe_ms);
    note.textContent = `Timed on ${c.audio_s.toFixed(1)} s of the recording.`;
    if (c.gpu) {
      const ratio = c.cpu.transcribe_ms / c.gpu.transcribe_ms;
      const v = document.createElement("p");
      v.className = "verdict";
      v.textContent = ratio >= 1.05 ? `The GPU is ${ratio.toFixed(1)}× faster` : ratio <= 0.95 ? `The CPU is ${(1 / ratio).toFixed(1)}× faster` : "About the same speed";
      box.insertBefore(v, note);
      note.textContent += ` Auto now uses the ${c.faster.toUpperCase()} for ${c.model} on this device.`;
      if (c.faster === "cpu" && ratio > 1) note.textContent += " (On phones the GPU has to be 1.3× faster: its first run per model stalls, and phone CPUs vary with heat.)";
      if (c.gpu.text !== c.cpu.text) {
        const alt = document.createElement("p");
        alt.className = "alt";
        alt.textContent = `CPU heard: “${c.cpu.text || "nothing"}”`;
        box.append(alt);
      }
    }
    btn.remove();
    await dictRefresh();
  } catch (e) {
    btn.disabled = false;
    for (const r of box.querySelectorAll(".bar")) r.remove();
    note.textContent = why(e);
  }
  compareBox = null;
  setState("Tap to talk");
  busy(false);
  dictRender();
}

// ---------------------------------------------------------------------------
// Chat: oriel.chat, a local LLM (llama.cpp) with the model's own chat
// template, streamed tokens and the conversation's KV cache reused per turn.

const chatState = { status: null, model: null, backend: "auto", messages: [], busy: false, bubble: null };

async function chatRefresh() {
  const st = await invoke("chat_status");
  chatState.status = st;
  if (!chatState.model || !st.models.some((m) => m.name === chatState.model)) {
    chatState.model = ([...st.models].reverse().find((m) => m.present) || st.models[0]).name;
  }
  const seg = $("chat-model");
  seg.innerHTML = "";
  for (const m of st.models) {
    const b = document.createElement("button");
    b.dataset.value = m.name;
    b.innerHTML = `${m.label}<small>${m.present ? '<span class="have">✓ ready</span>' : `${m.mb} MB`}</small>`;
    seg.append(b);
  }
  chatRender();
}
segmented($("chat-model"), (v) => { chatState.model = v; chatRender(); });
segmented($("chat-proc"), (v) => { chatState.backend = v; chatRender(); });

function chatRender() {
  const st = chatState.status;
  if (!st) return;
  const m = st.models.find((x) => x.name === chatState.model);
  for (const b of $("chat-model").querySelectorAll("button")) b.setAttribute("aria-checked", String(b.dataset.value === m.name));
  const gpuNow = st.gpu && (chatState.backend === "gpu" || (chatState.backend === "auto" && (m.faster ? m.faster === "gpu" : info && !info.android && info.os !== "ios")));
  const chipEl = $("chat-backend");
  chipEl.className = "chip status " + (gpuNow ? "gpu" : "cpu");
  chipEl.querySelector("b").textContent = `${m.label} · ${gpuNow ? `${st.backend} · ${st.gpu}` : "CPU"}`;
  $("chat-get").hidden = m.present;
  $("chat-have").hidden = !m.present;
  $("chat-have-text").textContent = `${m.mb} MB on this device`;
  $("chat-download").disabled = !!st.downloading;
  $("chat-delete").disabled = chatState.busy;
  for (const b of $("chat-proc").querySelectorAll("button")) {
    b.setAttribute("aria-checked", String(b.dataset.value === chatState.backend));
    if (b.dataset.value === "gpu") b.disabled = !st.gpu;
  }
  $("chat-proc-note").textContent = !st.gpu ? "No GPU backend here: the model runs on the CPU."
    : m.faster ? `Auto: the ${m.faster.toUpperCase()}, measured faster for ${m.label} on this device.`
    : "Auto: the GPU on desktops, the CPU on phones, until Compare measures it.";
  $("chat-compare").hidden = !st.gpu;
  $("chat-compare").disabled = chatState.busy || !m.present;
  const send = $("chat-send");
  send.disabled = !m.present && !chatState.busy;
  send.querySelector("use").setAttribute("href", chatState.busy ? "#i-stop" : "#i-send");
  send.setAttribute("aria-label", chatState.busy ? "Stop" : "Send");
  if (!chatState.busy) $("chat-state").textContent = m.present ? "" : `Download ${m.label} (${m.mb} MB) to chat`;
}

$("chat-download").addEventListener("click", async () => {
  const name = chatState.model;
  $("chat-download").disabled = true;
  $("chat-get").querySelector(".progress").hidden = false;
  let failed = null;
  try { await invoke("chat_download", { model: name }); } catch (e) { failed = `Download failed: ${e.message || e}`; }
  $("chat-get").querySelector(".progress").hidden = true;
  await chatRefresh();
  if (failed) $("chat-state").textContent = failed; // after the refresh, which resets it
});
listen("chat:download", (p) => {
  $("chat-progress").style.width = `${Math.round((100 * p.done_mb) / Math.max(1, p.total_mb))}%`;
  $("chat-state").textContent = `Downloading: ${p.done_mb} of ${p.total_mb} MB`;
});
$("chat-delete").addEventListener("click", () => armChatDelete());
let chatDeleteArmed = null;
async function armChatDelete() {
  const btn = $("chat-delete");
  if (!chatDeleteArmed) {
    btn.classList.add("confirm");
    btn.querySelector("span").textContent = "Tap to confirm";
    chatDeleteArmed = setTimeout(() => { chatDeleteArmed = null; btn.classList.remove("confirm"); btn.querySelector("span").textContent = "Delete"; }, 3000);
    return;
  }
  clearTimeout(chatDeleteArmed);
  chatDeleteArmed = null;
  btn.classList.remove("confirm");
  btn.querySelector("span").textContent = "Delete";
  try { await invoke("chat_delete", { model: chatState.model }); } catch (e) { $("chat-state").textContent = why(e); }
  await chatRefresh();
}

function bubble(role, text) {
  $("chat-empty").hidden = true;
  const b = document.createElement("div");
  b.className = `bubble ${role}`;
  const p = document.createElement("p");
  p.textContent = text;
  b.append(p);
  $("chat-log").append(b);
  b.scrollIntoView({ block: "end", behavior: "smooth" });
  return b;
}
listen("chat:token", (t) => {
  if (!chatState.bubble) return;
  const p = chatState.bubble.querySelector("p");
  p.textContent += t.text;
  chatState.bubble.scrollIntoView({ block: "end" });
});

const chatOptions = () => ({ model: chatState.model, backend: chatState.backend });

$("chat-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  if (chatState.busy) return invoke("chat_cancel");
  const text = $("chat-input").value.trim();
  if (!text) return;
  $("chat-input").value = "";
  autosize();
  chatState.messages.push({ role: "user", content: text });
  bubble("user", text);
  chatState.bubble = bubble("assistant", "");
  chatState.bubble.classList.add("typing");
  chatState.busy = true;
  chatRender();
  $("chat-state").textContent = "Thinking…";
  try {
    const r = await invoke("chat_send", { messages: [{ role: "system", content: "You are a helpful assistant. Answer briefly." }, ...chatState.messages], options: chatOptions() });
    chatState.messages.push({ role: "assistant", content: r.text });
    chatState.bubble.querySelector("p").textContent = r.text.trim() || "(no answer)";
    const meta = document.createElement("small");
    meta.textContent = `${r.backend} · ${r.tokens} tokens · ${r.tokens_per_s.toFixed(1)} tok/s` +
      (r.reused_tokens ? ` · ${r.reused_tokens} of ${r.prompt_tokens} prompt tokens reused` : "") +
      (r.load_ms ? ` · loaded in ${(r.load_ms / 1000).toFixed(1)} s` : "") + (r.stop === "cancelled" ? " · stopped" : "");
    chatState.bubble.append(meta);
    // Replies are Markdown: read as prose.
    if (r.text.trim()) chatState.bubble.append(readButton(r.text, true, (m) => { $("chat-state").textContent = m; }));
    $("chat-state").textContent = "";
  } catch (err) {
    chatState.messages.pop();
    chatState.bubble.querySelector("p").textContent = why(err);
    chatState.bubble.classList.add("error");
  }
  chatState.bubble.classList.remove("typing");
  chatState.bubble = null;
  chatState.busy = false;
  chatRender();
});
$("chat-input").addEventListener("keydown", (e) => {
  // Enter sends, Shift+Enter is a new line (with a keyboard).
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("chat-form").requestSubmit(); }
});
function autosize() {
  const t = $("chat-input");
  t.style.height = "auto";
  t.style.height = Math.min(t.scrollHeight, 160) + "px";
}
$("chat-input").addEventListener("input", autosize);

$("chat-new").addEventListener("click", () => {
  chatState.messages = [];
  $("chat-log").querySelectorAll(".bubble").forEach((b) => b.remove());
  $("chat-empty").hidden = false;
});

// Dictate into the message box: oriel.dictation with the Dictate tab's settings.
let chatMic = false;
$("chat-mic").addEventListener("click", async () => {
  const btn = $("chat-mic");
  try {
    if (!chatMic) {
      if ((await window.oriel.permissions.request("microphone")) !== "granted") return;
      if (!dict.status) await dictRefresh();
      chatMic = true;
      btn.classList.add("recording");
      $("chat-state").textContent = "Listening… tap the mic again to stop";
      await invoke("dictation_start", options());
    } else {
      chatMic = false;
      btn.classList.remove("recording");
      $("chat-state").textContent = "Transcribing…";
      const r = await invoke("dictation_stop");
      $("chat-input").value = [$("chat-input").value.trim(), r.text.trim()].filter(Boolean).join(" ");
      autosize();
      $("chat-state").textContent = "";
    }
  } catch (e) {
    chatMic = false;
    btn.classList.remove("recording");
    $("chat-state").textContent = why(e);
  }
});
listen("dictation:partial", (p) => { if (chatMic && p.text) $("chat-state").textContent = `“${p.text}”`; });

$("chat-compare").addEventListener("click", async () => {
  const out = $("chat-compare-out");
  out.innerHTML = '<div class="compare"><h3>GPU vs CPU, same prompt</h3><div class="bar gpu pending"><span>GPU</span><div class="track"><div class="fill"></div></div><b>…</b></div><div class="bar cpu pending"><span>CPU</span><div class="track"><div class="fill"></div></div><b>…</b></div><p class="alt">A short prompt and a 64-token answer on each…</p></div>';
  const box = out.firstChild;
  chatState.busy = true;
  chatRender();
  const fill = (cls, tps) => {
    const row = box.querySelector(`.bar.${cls}`);
    row.classList.remove("pending");
    row.dataset.v = tps;
    row.querySelector("b").textContent = `${tps.toFixed(1)} tok/s`;
    const rows = [...box.querySelectorAll(".bar[data-v]")];
    const max = Math.max(...rows.map((r) => +r.dataset.v));
    requestAnimationFrame(() => rows.forEach((r) => (r.querySelector(".fill").style.width = `${(100 * +r.dataset.v) / max}%`)));
  };
  const off = listen("chat:compare", (p) => fill(p.backend.toLowerCase(), p.tokens_per_s));
  try {
    const c = await invoke("chat_compare", chatOptions());
    if (c.gpu) fill("gpu", c.gpu.tokens_per_s); else box.querySelector(".bar.gpu").remove();
    fill("cpu", c.cpu.tokens_per_s);
    const ratio = c.gpu ? c.gpu.tokens_per_s / c.cpu.tokens_per_s : 0;
    box.querySelector(".alt").textContent = c.gpu
      ? `${ratio >= 1 ? `The GPU is ${ratio.toFixed(1)}×` : `The CPU is ${(1 / ratio).toFixed(1)}×`} faster. Auto now uses the ${c.faster.toUpperCase()} for this model.`
      : "No GPU here.";
  } catch (e) {
    box.querySelector(".alt").textContent = why(e);
  }
  if (typeof off === "function") off();
  chatState.busy = false;
  await chatRefresh();
});

function chatMaybeInit() {
  if (!chatState.status && location.hash === "#chat") chatRefresh().catch((e) => { $("chat-state").textContent = why(e); });
}
addEventListener("hashchange", chatMaybeInit);
chatMaybeInit();

// The first visit to the tab loads the GPU backend (a self-test): not at startup.
function dictMaybeInit() {
  if (!dict.status && (location.hash === "#dictate" || location.hash === "#app")) {
    dictRefresh().catch((e) => setState(`Error: ${e.message || e}`));
  }
}
addEventListener("hashchange", dictMaybeInit);
dictMaybeInit();


// ---------------------------------------------------------------------------
// Speak: oriel.tts, Kokoro 82M on this device. The text is cut into chunks
// and sound starts as soon as the first is ready; "tts:state" follows the
// utterance. "Read aloud" on chat replies and notes uses the same command.

const tts = { status: null, model: null, voice: "auto", speed: 1, backend: "auto", lang: "en-us", busy: false, btn: null, seq: 0, note: "" };

const ttsSamples = {
  en: "Hello! This is Oriel reading aloud, right on this device: nothing leaves it. Pick a voice, or leave it on Auto, which follows the language of the text.",
  es: "¡Hola! Soy Oriel y leo en voz alta en este dispositivo, sin enviar nada a internet. Elige una voz, o deja Auto, que sigue el idioma del texto.",
  fr: "Bonjour ! C'est Oriel qui lit à voix haute, directement sur cet appareil : rien n'en sort. Choisissez une voix, ou laissez Auto suivre la langue du texte.",
  md: "# What's new\n\n- **Speak**: text to speech with [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), offline.\n- *Read aloud* on chat replies and notes.\n\nMarkdown is read as prose: no asterisks, no web addresses spelled out.",
};
const langNames = { "en-us": "English (US)", "en-gb": "English (UK)", es: "Español", fr: "Français", "pt-br": "Português", it: "Italiano", ja: "日本語", zh: "中文", hi: "हिन्दी", ru: "Русский" };
const langName = (l) => langNames[l] || l;
const family = (l) => l.split("-")[0];
const ttsFile = (id) => (id.startsWith("kokoro-") ? `${id}.gguf` : `kokoro-voice-${id}.gguf`);
const voiceById = (id) => tts.status?.voices.find((v) => v.id === id);

function setTtsState(text) { $("tts-state").textContent = text; }

async function ttsRefresh() {
  const st = await invoke("tts_status");
  tts.status = st;
  if (!tts.model || !st.models.some((m) => m.id === tts.model)) tts.model = (st.models.find((m) => m.present) || st.models[0]).id;
  const seg = $("tts-model");
  seg.innerHTML = "";
  for (const m of st.models) {
    const b = document.createElement("button");
    b.dataset.value = m.id;
    b.innerHTML = `${m.id.split("-").pop().toUpperCase()}<small>${m.present ? '<span class="have">✓ ready</span>' : `${m.mb} MB`}</small>`;
    b.title = m.label;
    seg.append(b);
  }
  // Voices grouped by language (the catalog lists them so).
  const sel = $("tts-voice");
  sel.innerHTML = '<option value="auto">Auto: the language of the text</option>';
  let group = null;
  for (const v of st.voices) {
    const [lang, name] = v.label.split(" · ");
    if (group?.label !== lang) {
      group = document.createElement("optgroup");
      group.label = lang;
      sel.append(group);
    }
    const o = document.createElement("option");
    o.value = v.id;
    o.textContent = `${name || v.id}${v.present ? " ✓" : " (download)"}`;
    group.append(o);
  }
  if (tts.voice !== "auto" && !voiceById(tts.voice)) tts.voice = "auto";
  sel.value = tts.voice;
  const voicesHere = st.voices.filter((v) => v.present).length;
  $("dev-tts").textContent = `${st.loaded ? `${st.loaded} on ${st.backend}` : st.gpu ? `${st.backend} (${st.gpu})` : "CPU"} · ${voicesHere} voice${voicesHere === 1 ? "" : "s"}`;
  ttsRender();
}

// What Auto reads with: a voice of the language on the device, else one of
// its family, else any (oriel.tts's own order). `missing`: one to download.
function autoVoice(lang) {
  const vs = tts.status.voices;
  const here = vs.find((v) => v.present && v.lang === lang) || vs.find((v) => v.present && family(v.lang) === family(lang));
  const missing = here ? null : vs.find((v) => v.lang === lang) || vs.find((v) => family(v.lang) === family(lang)) || null;
  return { voice: here || vs.find((v) => v.present) || null, missing };
}

function ttsRender() {
  const st = tts.status;
  if (!st) return;
  const m = st.models.find((x) => x.id === tts.model);
  for (const b of $("tts-model").querySelectorAll("button")) b.setAttribute("aria-checked", String(b.dataset.value === m.id));
  // Where it runs: the loaded model's backend, else what Auto would use.
  const where = st.loaded === m.id ? st.backend : st.gpu && tts.backend === "auto" ? `${st.backend} · ${st.gpu}` : "CPU";
  const chipEl = $("tts-backend");
  chipEl.className = "chip status " + (where.startsWith("CPU") ? "cpu" : "gpu");
  chipEl.querySelector("b").textContent = `${m.label} · ${where}`;
  $("tts-get").hidden = m.present;
  $("tts-have").hidden = !m.present;
  $("tts-have-text").textContent = `${m.mb} MB on this device`;
  $("tts-missing").textContent = `Or copy ${ttsFile(m.id)} to ${st.models_dir}${info?.os === "windows" ? "\\" : "/"}`;
  $("tts-download").disabled = !!st.downloading;
  $("tts-delete").disabled = tts.busy;

  // The voice: picked, or what Auto reads this text with.
  let target = null; // a voice to offer for download
  let ready;
  const picked = tts.voice === "auto" ? null : voiceById(tts.voice);
  if (picked) {
    ready = picked.present;
    if (!picked.present) target = picked;
    $("tts-voice-note").textContent = `Reads in ${langName(picked.lang)}, whatever the text's language.`;
  } else {
    const a = autoVoice(tts.lang);
    ready = !!a.voice;
    target = a.missing;
    $("tts-voice-note").textContent = !a.voice ? `This text looks ${langName(tts.lang)}: download a voice for it.`
      : a.missing ? `This text looks ${langName(tts.lang)}, but there's no voice for it here: ${a.voice.label} reads it.`
      : `This text looks ${langName(tts.lang)}: ${a.voice.label} reads it.`;
  }
  $("tts-voice-have").hidden = !picked?.present;
  $("tts-voice-have-text").textContent = picked ? `${picked.label} on this device` : "";
  $("tts-voice-delete").disabled = tts.busy;
  $("tts-voice-get").hidden = !target;
  if (target) {
    $("tts-voice-get").dataset.id = target.id;
    $("tts-voice-download").querySelector("span").textContent = `Download ${target.label} (0.5 MB)`;
    $("tts-voice-download").disabled = !!st.downloading;
  }

  for (const b of $("tts-speed").querySelectorAll("button")) b.setAttribute("aria-checked", String(+b.dataset.value === tts.speed));
  $("tts-proc-field").hidden = !st.gpu;
  for (const b of $("tts-proc").querySelectorAll("button")) b.setAttribute("aria-checked", String(b.dataset.value === tts.backend));
  $("tts-proc-note").textContent = st.gpu ? `Auto: the GPU (${st.gpu}); a model it can't take runs on the CPU.` : "";
  $("tts-espeak").textContent = st.espeak_data ? `Phonemes: espeak-ng data in ${st.espeak_data}` : "No espeak-ng data found: speech can't start.";

  const mine = tts.busy && tts.btn === $("tts-speak");
  const btn = $("tts-speak");
  btn.disabled = !mine && (!m.present || !ready);
  btn.classList.toggle("speaking", mine);
  btn.querySelector("use").setAttribute("href", mine ? "#i-stop" : "#i-speaker");
  btn.querySelector("span").textContent = mine ? "Stop" : "Speak";
  if (!tts.busy) {
    setTtsState(!m.present ? `Download ${m.label} (${m.mb} MB) to speak`
      : !ready ? "Download a voice to speak"
      : !st.espeak_data ? why("EspeakDataMissing")
      : tts.note || "Ready");
  }
}

// The language Auto would read the text in (oriel.tts.guessLanguage).
let guessTimer = null;
function ttsGuess() {
  clearTimeout(guessTimer);
  guessTimer = setTimeout(async () => {
    try { tts.lang = await invoke("tts_guess", { text: $("tts-text").value }); } catch { /* keep the last one */ }
    ttsRender();
  }, 250);
}
$("tts-text").addEventListener("input", ttsGuess);
$("tts-text").addEventListener("keydown", (e) => {
  // Ctrl+Enter (Cmd+Enter): Speak or Stop.
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); if (!$("tts-speak").disabled) $("tts-speak").click(); }
});
$("tts-samples").addEventListener("click", (e) => {
  const b = e.target.closest("button");
  if (!b) return;
  $("tts-text").value = ttsSamples[b.dataset.lang];
  ttsGuess();
});
segmented($("tts-model"), (v) => { tts.model = v; ttsRender(); });
segmented($("tts-speed"), (v) => { tts.speed = +v; ttsRender(); });
segmented($("tts-proc"), (v) => { tts.backend = v; ttsRender(); });
$("tts-voice").addEventListener("change", () => { tts.voice = $("tts-voice").value; ttsRender(); });

// A speaker button shows a stop square while its utterance plays.
function markSpeaking(btn, on) {
  if (!btn || btn.id === "tts-speak") return;
  btn.classList.toggle("speaking", on);
  btn.querySelector("use").setAttribute("href", on ? "#i-stop" : "#i-speaker");
  btn.setAttribute("aria-label", on ? "Stop reading" : "Read aloud");
}

// Read `text` aloud for `btn` (the same button again: stop). A new one
// stops the current one (oriel.tts plays one utterance at a time); the
// replaced call returns with `stopped`. Null when this click only stopped.
async function say(text, options, btn) {
  if (tts.busy && tts.btn === btn) { await invoke("tts_stop"); return null; }
  const seq = ++tts.seq;
  markSpeaking(tts.btn, false);
  tts.busy = true;
  tts.btn = btn;
  markSpeaking(btn, true);
  ttsRender();
  try {
    return await invoke("tts_speak", { text, options: { speed: tts.speed, backend: tts.backend, ...options } });
  } finally {
    if (seq === tts.seq) {
      markSpeaking(btn, false);
      tts.busy = false;
      tts.btn = null;
      ttsRender();
    }
  }
}

function readButton(text, markdown, report) {
  const b = document.createElement("button");
  b.className = "btn ghost icon read";
  b.title = "Read aloud";
  b.setAttribute("aria-label", "Read aloud");
  b.innerHTML = '<svg><use href="#i-speaker"/></svg>';
  b.addEventListener("click", async (e) => {
    e.stopPropagation();
    try { await say(text, { markdown }, b); } catch (err) { report(speakWhy(err)); }
  });
  return b;
}

$("tts-speak").addEventListener("click", async () => {
  const btn = $("tts-speak");
  if (tts.busy && tts.btn === btn) return invoke("tts_stop");
  const text = $("tts-text").value.trim();
  if (!text) return setTtsState("Write something to read first.");
  const picked = tts.voice === "auto" ? null : voiceById(tts.voice);
  tts.note = "";
  setTtsState("Starting…");
  try {
    // A picked voice reads in its own language; Auto guesses it.
    const r = await say(text, { model: tts.model, voice: tts.voice, lang: picked ? picked.lang : "auto", markdown: $("tts-markdown").checked }, btn);
    if (r) { addSpoken(text, r); tts.note = r.stopped ? "Stopped" : "Finished"; }
  } catch (e) {
    tts.note = speakWhy(e);
  }
  ttsRender();
  ttsRefresh().catch(() => {}); // the backend it loaded on
});

listen("tts:state", (s) => {
  if (s.phase === "idle" && !tts.busy) return; // the page's own render says it
  const v = voiceById(s.voice);
  const label = { loading: "Loading the voice model…", generating: "Reading…", playing: `Speaking${v ? ` · ${v.label}` : ""}`,
    idle: s.message === "Stopped" ? "Stopped" : "Finished", error: speakWhy(s.message) }[s.phase] || s.phase;
  setTtsState(label);
});

// After each utterance: what it measured.
function addSpoken(text, r) {
  const card = document.createElement("div");
  card.className = "card transcript spoken";
  const p = document.createElement("p");
  p.textContent = text.length > 160 ? text.slice(0, 157) + "…" : text;
  const rtf = r.audio_s > 0 ? r.synth_ms / 1000 / r.audio_s : 0;
  const chips = document.createElement("div");
  chips.className = "chips";
  chips.append(
    chip(r.backend, r.backend !== "CPU" ? "gpu" : "cpu"),
    chip(voiceById(r.voice)?.label || r.voice),
    chip(`first audio ${r.first_audio_ms} ms`),
    chip(rtf ? `RTF ${rtf.toFixed(2)} · ${(1 / rtf).toFixed(1)}× real time` : "no audio"),
    chip(`${r.chunks} chunk${r.chunks === 1 ? "" : "s"} · ${r.audio_s.toFixed(1)} s`),
    chip(r.gap_ms ? `${r.gap_ms} ms of gaps` : "no gaps", r.gap_ms ? "cpu" : ""),
  );
  if (r.load_ms) chips.append(chip(`loaded in ${r.load_ms} ms`));
  if (r.stopped) chips.append(chip("stopped"));
  card.append(p, chips);
  $("tts-out").prepend(card);
  while ($("tts-out").children.length > 5) $("tts-out").lastChild.remove();
  tts.last = r;
}

async function ttsDownload(id, getEl, bar) {
  const btn = getEl.querySelector(".btn");
  btn.disabled = true;
  getEl.querySelector(".progress").hidden = false;
  $(bar).style.width = "0";
  tts.note = "";
  try { await invoke("tts_download", { id }); } catch (e) { tts.note = `Download failed: ${why(e)}`; }
  getEl.querySelector(".progress").hidden = true;
  await ttsRefresh();
}
$("tts-download").addEventListener("click", () => ttsDownload(tts.model, $("tts-get"), "tts-progress"));
$("tts-voice-download").addEventListener("click", () => ttsDownload($("tts-voice-get").dataset.id, $("tts-voice-get"), "tts-voice-progress"));
listen("tts:download", (p) => {
  const bar = p.id === tts.model ? "tts-progress" : "tts-voice-progress";
  $(bar).style.width = `${Math.round((100 * p.done_mb) / Math.max(1, p.total_mb))}%`;
  setTtsState(`Downloading ${p.id}: ${p.done_mb} of ${p.total_mb} MB`);
});

// Delete: a second tap within 3 s confirms.
function confirmTap(btn, run) {
  const label = btn.querySelector("span");
  if (!btn.classList.contains("confirm")) {
    btn.classList.add("confirm");
    label.textContent = "Tap to confirm";
    btn._disarm = setTimeout(() => { btn.classList.remove("confirm"); label.textContent = "Delete"; }, 3000);
    return;
  }
  clearTimeout(btn._disarm);
  btn.classList.remove("confirm");
  label.textContent = "Delete";
  run();
}
async function ttsDelete(id) {
  tts.note = "";
  try { await invoke("tts_delete", { id }); } catch (e) { tts.note = `Couldn't delete ${id}: ${speakWhy(e)}`; }
  await ttsRefresh();
}
$("tts-delete").addEventListener("click", () => confirmTap($("tts-delete"), () => ttsDelete(tts.model)));
$("tts-voice-delete").addEventListener("click", () => confirmTap($("tts-voice-delete"), () => ttsDelete(tts.voice)));

// With a model and a voice on the device, load them now (on a GPU, also
// its pipelines): the first Speak then starts in well under a second.
// Quietly: a missing model is the download row's to explain.
function ttsWarmUp() {
  const st = tts.status;
  if (!st?.models.some((m) => m.present) || !st.voices.some((v) => v.present)) return;
  invoke("tts_warm_up", { model: tts.model, voice: tts.voice, backend: tts.backend }).catch(() => {});
}

// The first visit to the tab (or the App tab) asks for the status, which
// loads the GPU backend (a self-test): not at startup.
function ttsMaybeInit() {
  if (!tts.status && (location.hash === "#speak" || location.hash === "#app")) {
    ttsRefresh().then(ttsGuess).then(ttsWarmUp).catch((e) => setTtsState(why(e)));
  }
}
addEventListener("hashchange", ttsMaybeInit);
ttsMaybeInit();

// Keyboard shortcuts (Android, hardware keyboard): registered in Zig, so
// they're listed in the system's Meta+/ helper.
listen("shortcut", ({ id }) => {
  if (id.startsWith("tab:")) { location.hash = "#" + id.slice(4); return; }
  if (id === "dictate") {
    if (location.hash !== "#dictate") location.hash = "#dictate";
    const rec = $("dict-rec");
    if (!rec.disabled) rec.click();
  }
});
