const logList = document.getElementById("log-list");
const statusBadge = document.getElementById("status-badge");

function addLog(text, type = "") {
  const div = document.createElement("div");
  div.className = "log-entry" + (type ? " " + type : "");
  div.textContent = `[${new Date().toLocaleTimeString()}] ${text}`;
  logList.prepend(div);
}

document.getElementById("btn-clear").addEventListener("click", () => {
  logList.innerHTML = "";
});

document.getElementById("btn-trigger").addEventListener("click", async () => {
  try {
    statusBadge.textContent = "Processing...";
    statusBadge.style.color = "#f59e0b";
    addLog("Manually triggered rewrite pipeline...");
    const res = await window.oriel.invoke("trigger_pipeline", {});
    addLog(`Pipeline result: "${res.rewritten}" (original: "${res.original}")`, "success");
  } catch (err) {
    addLog(`Pipeline error: ${err}`, "system");
  } finally {
    statusBadge.textContent = "Ready";
    statusBadge.style.color = "";
  }
});

document.getElementById("btn-read").addEventListener("click", async () => {
  try {
    const text = await window.oriel.invoke("read_clipboard", {});
    addLog(`Clipboard content: "${text}"`, "system");
  } catch (err) {
    addLog(`Read error: ${err}`, "system");
  }
});

document.getElementById("btn-notify").addEventListener("click", async () => {
  try {
    await window.oriel.invoke("send_notification", {
      title: "GhostPen Lite",
      body: "Hotkey Ctrl+Alt+G is registered and active!",
    });
    addLog("Sent desktop notification", "system");
  } catch (err) {
    addLog(`Notification error: ${err}`, "system");
  }
});

// Listen for global hotkey / pipeline completion events from Zig
window.oriel.listen("pipeline_completed", (ev) => {
  addLog(`Hotkey triggered pipeline: "${ev.rewritten}" (from "${ev.original}")`, "success");
});

window.oriel.listen("hotkey_pressed", (ev) => {
  addLog(`Hotkey detected: ${ev.id}`, "system");
});

// Auto-quit check mode for headless testing
if (location.search.includes("auto-quit")) {
  (async () => {
    try {
      addLog("Running auto-quit test pipeline...");
      // 1. Write text to clipboard
      await window.oriel.invoke("write_clipboard", { text: "ghostpen webview test input" });
      // 2. Trigger pipeline
      const res = await window.oriel.invoke("trigger_pipeline", {});
      if (!res.rewritten.includes("ghostpen webview test input")) {
        throw new Error("Pipeline output did not include original text");
      }
      // 3. Read back clipboard
      const clip = await window.oriel.invoke("read_clipboard", {});
      if (!clip.includes("Rewritten:")) {
        throw new Error("Clipboard was not updated with rewritten text");
      }
      addLog("Auto-quit checks passed!", "success");
      await window.oriel.invoke("done", { failed: 0, report: "[ok] ghostpen-lite webview pipeline test passed" });
    } catch (err) {
      addLog(`Auto-quit failed: ${err.message}`, "system");
      await window.oriel.invoke("done", { failed: 1, report: `[FAIL] ghostpen-lite webview: ${err.message}` });
    }
  })();
}

// ---- Live captions ---------------------------------------------------------
const sourceSel = document.getElementById("caption-source");
const langSel = document.getElementById("caption-lang");
const captionsBtn = document.getElementById("btn-captions");
const captionsBox = document.getElementById("captions");
const backendBadge = document.getElementById("backend-badge");
let captionsOn = false;
let partialEl = null;

async function loadCaptionSources() {
  try {
    const status = await window.oriel.invoke("captions_status", {});
    backendBadge.textContent = status.gpu ? `GPU · ${status.gpu}` : "CPU";
    backendBadge.classList.toggle("gpu", !!status.gpu);
    const sources = await window.oriel.invoke("audio_sources", {});
    sourceSel.innerHTML = "";
    for (const s of sources) {
      const opt = document.createElement("option");
      opt.value = s.name;
      opt.textContent = (s.monitor ? "🔊 System audio: " : "🎤 ") + s.description;
      sourceSel.append(opt);
    }
  } catch (err) {
    addLog(`Captions unavailable: ${err}`, "system");
  }
}

function showCaption(text, final) {
  captionsBox.querySelector(".caption-hint")?.remove();
  if (!partialEl) {
    partialEl = document.createElement("div");
    captionsBox.append(partialEl);
  }
  partialEl.textContent = text;
  partialEl.className = final ? "caption final" : "caption partial";
  if (final) partialEl = null;
  while (captionsBox.children.length > 50) captionsBox.firstChild.remove();
  captionsBox.scrollTop = captionsBox.scrollHeight;
}

captionsBtn.addEventListener("click", async () => {
  captionsBtn.disabled = true;
  try {
    if (captionsOn) {
      await window.oriel.invoke("captions_stop", {});
      captionsOn = false;
    } else {
      await window.oriel.invoke("captions_start", { source: sourceSel.value || null, language: langSel.value });
      captionsOn = true;
      addLog(`Captions started: ${sourceSel.selectedOptions[0]?.textContent ?? "default input"}`, "success");
    }
  } catch (err) {
    addLog(`Captions error: ${err}`, "system");
  } finally {
    captionsBtn.disabled = false;
    captionsBtn.textContent = captionsOn ? "⏹ Stop" : "🎙 Start";
  }
});

window.oriel.listen("caption", (ev) => {
  showCaption(ev.text, ev.final);
  if (ev.final) backendBadge.title = `last: ${ev.audio_ms} ms of audio in ${ev.whisper_ms} ms`;
});

window.oriel.listen("captions_error", (ev) => {
  addLog(`Captions: ${ev.message} (${ev.error_name})`, "system");
  captionsOn = false;
  captionsBtn.textContent = "🎙 Start";
});

loadCaptionSources().then(() => {
  if (location.search.includes("captions-demo")) captionsBtn.click();
});
