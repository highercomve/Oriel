// Oriel System Monitor Client Logic
(function () {
  const $ = (id) => document.getElementById(id);

  // Configuration
  const HISTORY_LEN = 60;
  const SAMPLE_INTERVAL_MS = 2000;

  // State
  let samplingActive = true;
  let sampleTimer = null;
  let lastSampleData = null;
  let currentSortKey = "cpu";
  let sortAscending = false;
  let filterText = "";
  let pendingKill = null; // { pid, name }

  // 60-sample historical ring buffers
  const cpuHistory = [];
  const memHistory = [];
  const procHistory = [];

  // DOM Elements
  const elEngineBadge = $("engine-badge");
  const elPerfBadge = $("perf-badge");
  const elHeaderStatus = $("header-status");
  const elCpuValue = $("cpu-value");
  const elCpuDetail = $("cpu-detail");
  const elMemValue = $("mem-value");
  const elMemDetail = $("mem-detail");
  const elProcValue = $("proc-value");
  const elProcDetail = $("proc-detail");
  const elUptimeValue = $("uptime-value");
  const elCountBadge = $("count-badge");
  const elProcTbody = $("proc-tbody");
  const elEmptyState = $("empty-state");
  const elFooterStatus = $("footer-status");
  const elFooterEngine = $("footer-engine");
  const elSearchInput = $("search-input");
  const elSearchClear = $("search-clear");
  const elBtnPause = $("btn-pause");
  const elPauseIcon = $("pause-icon");
  const elPauseLabel = $("pause-label");
  const elBtnRefresh = $("btn-refresh");
  const elBtnSortDir = $("btn-sort-dir");
  const elSortDirIcon = $("sort-dir-icon");
  const elKillModal = $("kill-modal");
  const elKillProcName = $("kill-proc-name");
  const elKillProcPid = $("kill-proc-pid");
  const elKillCancel = $("kill-cancel");
  const elKillConfirm = $("kill-confirm");

  // Format Helpers
  function formatBytes(bytes) {
    if (bytes == null || isNaN(bytes)) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    let val = bytes;
    while (val >= 1024 && i < units.length - 1) {
      val /= 1024;
      i++;
    }
    return val >= 10 || i === 0 ? `${Math.round(val)} ${units[i]}` : `${val.toFixed(1)} ${units[i]}`;
  }

  function formatUptime(sec) {
    if (!sec) return "0m";
    const d = Math.floor(sec / 86400);
    const h = Math.floor((sec % 86400) / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (d > 0) return `${d}d ${h}h ${m}m`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
  }

  function formatClock(date) {
    const pad = (n) => String(n).padStart(2, "0");
    return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  }

  // Draw Sparklines into HTML5 Canvas (compatible with Oriel native_ui Cairo/Direct2D)
  function drawSparkline(canvasId, values, minVal, maxVal, barColor, isArea = false) {
    const canvas = $(canvasId);
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const w = canvas.width;
    const h = canvas.height;
    ctx.clearRect(0, 0, w, h);

    if (values.length === 0) return;

    const count = HISTORY_LEN;
    const step = w / count;
    const range = (maxVal - minVal) || 1;

    if (isArea) {
      // Area sparkline (for Process count)
      ctx.beginPath();
      const startX = w - values.length * step;
      let firstX = startX;
      let firstY = h;

      for (let i = 0; i < values.length; i++) {
        const x = startX + i * step;
        const normalized = Math.max(0, Math.min(1, (values[i] - minVal) / range));
        const y = h - (normalized * (h - 4)) - 2;
        if (i === 0) {
          ctx.moveTo(x, y);
          firstX = x;
          firstY = y;
        } else {
          ctx.lineTo(x, y);
        }
      }

      ctx.strokeStyle = barColor;
      ctx.lineWidth = 1.5;
      ctx.stroke();

      // Close polygon to baseline for area fill
      const lastX = startX + (values.length - 1) * step;
      ctx.lineTo(lastX, h);
      ctx.lineTo(firstX, h);
      ctx.closePath();
      ctx.fillStyle = "rgba(57, 197, 187, 0.12)";
      ctx.fill();
    } else {
      // Bar series sparkline (for CPU and Memory)
      const barW = Math.max(2, step - 1);
      const startX = w - values.length * step;

      ctx.fillStyle = barColor;
      for (let i = 0; i < values.length; i++) {
        const x = startX + i * step;
        const val = values[i];
        const normalized = Math.max(0, Math.min(1, (val - minVal) / range));
        const barH = Math.max(2, normalized * (h - 4));
        const y = h - barH;
        ctx.fillRect(x, y, barW, barH);
      }
    }
  }

  // Sample Execution
  async function performSample() {
    if (!window.oriel || !window.oriel.invoke) {
      elFooterStatus.textContent = "Running in browser preview (Oriel IPC unavailable)";
      return;
    }

    try {
      const sample = await window.oriel.invoke("sample");
      if (!sample) return;

      lastSampleData = sample;
      applySample(sample);
    } catch (err) {
      console.error("Sample failed:", err);
      elHeaderStatus.textContent = `Sample error: ${err.message || err}`;
    }
  }

  function applySample(sample) {
    const now = new Date();

    // 1. Update engine & latency badges
    if (sample.sample_time_ms != null) {
      elPerfBadge.textContent = `⚡ ${sample.sample_time_ms.toFixed(2)} ms`;
    }
    if (sample.engine) {
      elFooterEngine.textContent = sample.engine;
    }

    // 2. CPU
    const cpuPct = sample.cpu.percent || 0;
    elCpuValue.textContent = `${cpuPct.toFixed(1)}%`;
    const cleanModel = sample.cpu.model
      ? sample.cpu.model.replace(/Processor|8-Core|16-Core|Processor/gi, "").trim()
      : "Host CPU";
    elCpuDetail.textContent = `${sample.cpu.cores} cores · ${cleanModel}`;
    elCpuDetail.title = `${sample.cpu.cores} cores · ${sample.cpu.model || ""}`;
    cpuHistory.push(cpuPct);
    if (cpuHistory.length > HISTORY_LEN) cpuHistory.shift();
    drawSparkline("cpu-chart", cpuHistory, 0, 100, "#39c5bb", false);

    // 3. Memory
    const memPct = sample.mem.percent || 0;
    elMemValue.textContent = `${memPct.toFixed(1)}%`;
    const memUsedStr = formatBytes(sample.mem.used_bytes);
    const memTotalStr = formatBytes(sample.mem.total_bytes);
    elMemDetail.textContent = `${memUsedStr} / ${memTotalStr}`;
    memHistory.push(memPct);
    if (memHistory.length > HISTORY_LEN) memHistory.shift();
    drawSparkline("mem-chart", memHistory, 0, 100, "#58a6ff", false);

    // 4. Processes Count
    const totalCount = sample.total_processes || sample.processes.length || 0;
    elProcValue.textContent = String(totalCount);
    elProcDetail.textContent = `top ${sample.processes.length} shown`;
    procHistory.push(totalCount);
    if (procHistory.length > HISTORY_LEN) procHistory.shift();
    const minProcs = Math.min(...procHistory) * 0.9;
    const maxProcs = Math.max(...procHistory) * 1.1;
    drawSparkline("proc-chart", procHistory, minProcs, maxProcs, "#39c5bb", true);

    // 5. Uptime
    elUptimeValue.textContent = formatUptime(sample.uptime_seconds);

    // 6. Header & Status
    elHeaderStatus.textContent = samplingActive
      ? `Sampling every 2.0s · Last sample at ${formatClock(now)}`
      : `Sampling paused · Last sample at ${formatClock(now)}`;

    // 7. Render Process Table
    renderTable();
  }

  function renderTable() {
    if (!lastSampleData || !lastSampleData.processes) return;

    let rows = [...lastSampleData.processes];

    // Filter
    if (filterText.trim().length > 0) {
      const q = filterText.trim().toLowerCase();
      rows = rows.filter((r) => {
        return String(r.pid).includes(q) || (r.name && r.name.toLowerCase().includes(q));
      });
    }

    // Sort with robust tie-breaking
    rows.sort((a, b) => {
      let diff = 0;
      if (currentSortKey === "cpu") {
        diff = (a.cpu_percent - b.cpu_percent) || (a.mem_rss_bytes - b.mem_rss_bytes);
      } else if (currentSortKey === "mem") {
        diff = (a.mem_rss_bytes - b.mem_rss_bytes) || (a.cpu_percent - b.cpu_percent);
      } else if (currentSortKey === "pid") {
        diff = a.pid - b.pid;
      } else if (currentSortKey === "name") {
        diff = (a.name || "").localeCompare(b.name || "");
      }
      return sortAscending ? diff : -diff;
    });

    elCountBadge.textContent = `${rows.length} of ${lastSampleData.total_processes}`;

    if (rows.length === 0) {
      elProcTbody.innerHTML = "";
      elEmptyState.classList.remove("hidden");
      return;
    }

    elEmptyState.classList.add("hidden");

    // Build rows HTML
    const frag = document.createDocumentFragment();
    for (const r of rows) {
      const row = document.createElement("div");
      row.className = "table-row";

      // Right-click context menu with submenus
      row.oncontextmenu = (e) => {
        showContextMenu(e, r);
      };

      const elPid = document.createElement("div");
      elPid.className = "col-pid";
      elPid.textContent = String(r.pid);

      const elName = document.createElement("div");
      elName.className = "col-name";
      elName.textContent = r.name || "unknown";
      elName.title = r.name || "";

      const elState = document.createElement("div");
      elState.className = "col-state";
      elState.textContent = r.state || "?";

      const elCpu = document.createElement("div");
      elCpu.className = "col-cpu";
      elCpu.textContent = `${r.cpu_percent.toFixed(1)}%`;

      const elMem = document.createElement("div");
      elMem.className = "col-mem";
      elMem.textContent = formatBytes(r.mem_rss_bytes);

      const elActions = document.createElement("div");
      elActions.className = "col-actions";

      // Terminate Button
      const btnKill = document.createElement("button");
      btnKill.className = "row-btn btn-kill-row";
      btnKill.textContent = "Terminate…";
      btnKill.title = `Send SIGTERM to ${r.name} (${r.pid})`;
      btnKill.onclick = (e) => {
        e.stopPropagation();
        openKillModal(r.pid, r.name);
      };

      // Copy Name Button
      const btnCopy = document.createElement("button");
      btnCopy.className = "row-btn";
      btnCopy.textContent = "Copy";
      btnCopy.title = "Copy process name";
      btnCopy.onclick = (e) => {
        e.stopPropagation();
        copyText(r.name, "process name");
      };

      elActions.appendChild(btnKill);
      elActions.appendChild(btnCopy);

      row.appendChild(elPid);
      row.appendChild(elName);
      row.appendChild(elState);
      row.appendChild(elCpu);
      row.appendChild(elMem);
      row.appendChild(elActions);

      frag.appendChild(row);
    }

    elProcTbody.replaceChildren(frag);
  }

  // Actions
  function toggleSampling() {
    samplingActive = !samplingActive;
    if (samplingActive) {
      elPauseIcon.textContent = "⏸";
      elPauseLabel.textContent = "Pause";
      elHeaderStatus.textContent = "Resuming sampling...";
      startLoop();
      performSample();
    } else {
      elPauseIcon.textContent = "▶";
      elPauseLabel.textContent = "Resume";
      elHeaderStatus.textContent = "Sampling paused";
      stopLoop();
    }
  }

  function startLoop() {
    stopLoop();
    sampleTimer = setInterval(performSample, SAMPLE_INTERVAL_MS);
  }

  function stopLoop() {
    if (sampleTimer) {
      clearInterval(sampleTimer);
      sampleTimer = null;
    }
  }

  async function copyText(text, label = "text") {
    if (window.oriel && window.oriel.invoke) {
      try {
        const ok = await window.oriel.invoke("copy_to_clipboard", { text });
        if (ok) {
          elFooterStatus.textContent = `Copied ${label} to clipboard`;
          return;
        }
      } catch (_) {}
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => {
        elFooterStatus.textContent = `Copied ${label} to clipboard`;
      });
    } else {
      elFooterStatus.textContent = `Copied ${label}`;
    }
  }

  // Context Menu State & Logic
  let contextTargetRow = null;
  const elContextMenu = $("context-menu");

  function showContextMenu(e, rowData) {
    e.preventDefault();
    e.stopPropagation();
    contextTargetRow = rowData;

    if (!elContextMenu) return;
    elContextMenu.classList.remove("hidden");

    // Position menu safely inside window viewport
    const menuW = 210;
    const menuH = 190;
    let x = e.clientX || 0;
    let y = e.clientY || 0;

    if (x + menuW > window.innerWidth) {
      x = Math.max(10, window.innerWidth - menuW - 10);
    }
    if (y + menuH > window.innerHeight) {
      y = Math.max(10, window.innerHeight - menuH - 10);
    }

    elContextMenu.style.left = `${x}px`;
    elContextMenu.style.top = `${y}px`;
  }

  function hideContextMenu() {
    if (elContextMenu) elContextMenu.classList.add("hidden");
    contextTargetRow = null;
  }

  function openKillModal(pid, name) {
    pendingKill = { pid, name };
    elKillProcName.textContent = name;
    elKillProcPid.textContent = String(pid);
    elKillModal.classList.remove("hidden");
  }

  function closeKillModal() {
    pendingKill = null;
    elKillModal.classList.add("hidden");
  }

  async function confirmKill() {
    if (!pendingKill) return;
    const { pid, name } = pendingKill;
    closeKillModal();

    if (window.oriel && window.oriel.invoke) {
      try {
        const ok = await window.oriel.invoke("terminate_process", { pid: pid });
        if (ok) {
          elFooterStatus.textContent = `Sent SIGTERM to ${name} (PID ${pid})`;
          performSample();
        } else {
          elFooterStatus.textContent = `Failed to send SIGTERM to PID ${pid} (permission denied or exited)`;
        }
      } catch (err) {
        elFooterStatus.textContent = `Error terminating process: ${err}`;
      }
    }
  }

  // Event Listeners
  elBtnPause.onclick = toggleSampling;
  elBtnRefresh.onclick = performSample;

  elSearchInput.oninput = () => {
    filterText = elSearchInput.value;
    if (filterText.length > 0) {
      elSearchClear.classList.remove("hidden");
    } else {
      elSearchClear.classList.add("hidden");
    }
    renderTable();
  };

  elSearchClear.onclick = () => {
    elSearchInput.value = "";
    filterText = "";
    elSearchClear.classList.add("hidden");
    renderTable();
    elSearchInput.focus();
  };

  // Sort toggles
  document.querySelectorAll(".sort-group .btn-toggle").forEach((btn) => {
    btn.onclick = () => {
      document.querySelectorAll(".sort-group .btn-toggle").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      currentSortKey = btn.dataset.sort;
      renderTable();
    };
  });

  elBtnSortDir.onclick = () => {
    sortAscending = !sortAscending;
    elSortDirIcon.textContent = sortAscending ? "▲" : "▼";
    renderTable();
  };

  // Context Menu Actions
  const ctxTerm = $("ctx-terminate");
  if (ctxTerm) {
    ctxTerm.onclick = (e) => {
      e.stopPropagation();
      if (contextTargetRow) {
        const { pid, name } = contextTargetRow;
        hideContextMenu();
        openKillModal(pid, name);
      }
    };
  }

  const ctxCopyName = $("ctx-copy-name");
  if (ctxCopyName) {
    ctxCopyName.onclick = (e) => {
      e.stopPropagation();
      if (contextTargetRow) {
        const name = contextTargetRow.name;
        hideContextMenu();
        copyText(name, "process name");
      }
    };
  }

  const ctxCopyPid = $("ctx-copy-pid");
  if (ctxCopyPid) {
    ctxCopyPid.onclick = (e) => {
      e.stopPropagation();
      if (contextTargetRow) {
        const pid = String(contextTargetRow.pid);
        hideContextMenu();
        copyText(pid, "PID");
      }
    };
  }

  const ctxCopyLine = $("ctx-copy-line");
  if (ctxCopyLine) {
    ctxCopyLine.onclick = (e) => {
      e.stopPropagation();
      if (contextTargetRow) {
        const line = `${contextTargetRow.pid}\t${contextTargetRow.name}\t${contextTargetRow.cpu_percent.toFixed(1)}%\t${formatBytes(contextTargetRow.mem_rss_bytes)}`;
        hideContextMenu();
        copyText(line, "row details");
      }
    };
  }

  const ctxFilter = $("ctx-filter");
  if (ctxFilter) {
    ctxFilter.onclick = (e) => {
      e.stopPropagation();
      if (contextTargetRow) {
        const name = contextTargetRow.name;
        hideContextMenu();
        elSearchInput.value = name;
        filterText = name;
        elSearchClear.classList.remove("hidden");
        renderTable();
      }
    };
  }

  const ctxRefresh = $("ctx-refresh");
  if (ctxRefresh) {
    ctxRefresh.onclick = (e) => {
      e.stopPropagation();
      hideContextMenu();
      performSample();
    };
  }

  // Dismiss context menu on click or escape
  window.addEventListener("click", hideContextMenu);
  window.addEventListener("contextmenu", (e) => {
    if (!e.target.closest("#proc-tbody .table-row")) {
      hideContextMenu();
    }
  });
  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      hideContextMenu();
      closeKillModal();
    }
  });

  // Modal actions
  elKillCancel.onclick = closeKillModal;
  elKillConfirm.onclick = confirmKill;
  elKillModal.onclick = (e) => {
    if (e.target === elKillModal) closeKillModal();
  };

  // Initialize
  async function init() {
    if (window.oriel && window.oriel.invoke) {
      try {
        const meta = await window.oriel.invoke("get_meta");
        if (meta) {
          elEngineBadge.textContent = meta.native_ui ? "native_ui" : "WebView";
          if (!meta.native_ui) {
            elEngineBadge.className = "badge badge-secondary";
          }
        }
      } catch (_) {}
    }

    startLoop();
    performSample();
  }

  init();
})();
