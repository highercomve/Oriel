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
