// Oriel System Monitor Client Logic
(function () {
  const $ = (id) => document.getElementById(id);

  // Configuration
  const HISTORY_LEN = 60;
  const SETTINGS_KEY = "oriel-system-monitor:settings";

  // The parts of the page Settings shows and hides. Hidden parts cost
  // nothing: they aren't updated or drawn.
  const SECTIONS = [
    { key: "tiles", label: "Summary tiles", el: "sec-tiles" },
    { key: "system", label: "System", el: "sec-system" },
    { key: "cpu", label: "CPU details", el: "sec-cpu" },
    { key: "mem", label: "Memory", el: "sec-mem" },
    { key: "disks", label: "Disks", el: "sec-disks" },
    { key: "net", label: "Network", el: "sec-net" },
    { key: "sensors", label: "Sensors", el: "sec-sensors" },
    { key: "proc", label: "Processes", el: "sec-proc" },
  ];
  const PANEL_KEYS = ["mem", "disks", "net", "sensors"];

  const settings = loadSettings();

  function loadSettings() {
    const defaults = { interval: 2000, netIface: null, show: {} };
    for (const s of SECTIONS) defaults.show[s.key] = true;
    try {
      const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) || "null");
      if (saved && typeof saved === "object") {
        if ([1000, 2000, 5000].includes(saved.interval)) defaults.interval = saved.interval;
        if (typeof saved.netIface === "string") defaults.netIface = saved.netIface;
        if (saved.show) for (const s of SECTIONS) if (typeof saved.show[s.key] === "boolean") defaults.show[s.key] = saved.show[s.key];
      }
    } catch (_) {}
    return defaults;
  }

  function saveSettings() {
    try {
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
    } catch (_) {}
  }

  // Parts the OS can't fill (Windows and macOS share no temperatures):
  // hidden, whatever Settings says.
  const unavailable = new Set();
  const shown = (key) => settings.show[key] !== false && !unavailable.has(key);

  // State
  let samplingActive = true;
  let sampleTimer = null;
  let lastSampleData = null;
  let currentSortKey = "cpu";
  let sortAscending = false;
  let filterText = "";
  let pendingKill = null; // { pid, name }
  let lastUptime = 0;

  // 60-sample historical ring buffers
  const cpuHistory = [];
  const userHistory = [];
  const systemHistory = [];
  const iowaitHistory = [];
  const memHistory = [];
  const procHistory = [];
  const coreHistory = []; // one per core
  const netHistory = new Map(); // interface → { rx: [], tx: [] }

  // DOM Elements
  const elEngineBadge = $("engine-badge");
  const elPerfBadge = $("perf-badge");
  const elHeaderStatus = $("header-status");
  const elStatusDot = $("status-dot");
  const elCpuValue = $("cpu-value");
  const elCpuDetail = $("cpu-detail");
  const elCpuToggle = $("cpu-toggle");
  const elMemValue = $("mem-value");
  const elMemDetail = $("mem-detail");
  const elProcValue = $("proc-value");
  const elProcDetail = $("proc-detail");
  const elUptimeValue = $("uptime-value");
  const elCadenceNote = $("cadence-note");
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
  const elSettings = $("settings");
  const elCoreGrid = $("core-grid");
  const elDiskList = $("disk-list");
  const elSensorList = $("sensor-list");

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

  const formatRate = (bps) => `${formatBytes(bps)}/s`;

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

  const formatGhz = (mhz) => (mhz > 0 ? `${(mhz / 1000).toFixed(1)} GHz` : "-- GHz");

  /** Push onto a history buffer, keeping the last HISTORY_LEN values. */
  function pushHistory(arr, v) {
    arr.push(v);
    if (arr.length > HISTORY_LEN) arr.shift();
  }

  /** Set an element's text only when it differs; true when it changed. */
  function setText(el, text) {
    if (el.textContent === text) return false;
    el.textContent = text;
    return true;
  }

  /** A bar's fill to a percentage, touched only when the whole number changes. */
  function setFill(fill, percent) {
    const w = Math.max(0, Math.min(100, Math.round(percent)));
    if (fill._w === w) return;
    fill._w = w;
    fill.style.width = `${w}%`;
  }

  function setClass(el, cls, on) {
    if (el.classList.contains(cls) !== on) el.classList.toggle(cls, on);
  }

  function tempClass(c) {
    return c >= 85 ? "critical" : c >= 70 ? "hot" : c >= 50 ? "warm" : "";
  }

  // Canvases: their bitmaps sized to their boxes (on resize, and when a
  // part is shown), so lines stay crisp instead of stretched.
  function fitCanvas(canvas) {
    if (!canvas || !canvas.getBoundingClientRect) return;
    const r = canvas.getBoundingClientRect();
    const w = Math.round(r.width);
    const h = Math.round(r.height);
    if (w > 0 && h > 0 && (canvas.width !== w || canvas.height !== h)) {
      canvas.width = w;
      canvas.height = h;
    }
  }

  function fitCanvases() {
    for (const id of ["cpu-chart", "mem-chart", "proc-chart", "cpu-big", "net-chart"]) fitCanvas($(id));
    for (const c of coreRows) fitCanvas(c.canvas);
  }

  // Draw Sparklines into HTML5 Canvas (compatible with Oriel native_ui Cairo/Direct2D)
  function drawSparkline(canvas, values, minVal, maxVal, barColor, isArea = false) {
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const w = canvas.width;
    const h = canvas.height;
    ctx.clearRect(0, 0, w, h);

    if (values.length === 0) return;

    const step = w / HISTORY_LEN;
    const range = (maxVal - minVal) || 1;

    if (isArea) {
      // Area sparkline (for Process count)
      ctx.beginPath();
      const startX = w - values.length * step;
      let firstX = startX;

      for (let i = 0; i < values.length; i++) {
        const x = startX + i * step;
        const normalized = Math.max(0, Math.min(1, (values[i] - minVal) / range));
        const y = h - (normalized * (h - 4)) - 2;
        if (i === 0) {
          ctx.moveTo(x, y);
          firstX = x;
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
      const barW = Math.max(1, step - 1);
      const startX = w - values.length * step;

      ctx.fillStyle = barColor;
      for (let i = 0; i < values.length; i++) {
        const x = startX + i * step;
        const normalized = Math.max(0, Math.min(1, (values[i] - minVal) / range));
        const barH = Math.max(1, normalized * (h - 2));
        ctx.fillRect(x, h - barH, barW, barH);
      }
    }
  }

  /** The CPU graph: user, system and iowait stacked per sample. */
  function drawCpuStack() {
    const canvas = $("cpu-big");
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const w = canvas.width;
    const h = canvas.height;
    ctx.clearRect(0, 0, w, h);
    // Grid lines at 25 / 50 / 75 %.
    ctx.fillStyle = "rgba(139, 148, 158, 0.12)";
    for (const q of [0.25, 0.5, 0.75]) ctx.fillRect(0, Math.round(h * q), w, 1);
    const n = userHistory.length;
    if (n === 0) return;
    const step = w / HISTORY_LEN;
    const barW = Math.max(1, step - 1);
    const startX = w - n * step;
    const layers = [
      [userHistory, "#39c5bb"],
      [systemHistory, "#58a6ff"],
      [iowaitHistory, "#d29922"],
    ];
    for (let i = 0; i < n; i++) {
      const x = startX + i * step;
      let y = h;
      for (const [arr, color] of layers) {
        const bh = Math.max(0, Math.min(1, arr[i] / 100)) * (h - 2);
        if (bh <= 0) continue;
        ctx.fillStyle = color;
        ctx.fillRect(x, y - bh, barW, bh);
        y -= bh;
      }
    }
  }

  /** The network graph: download up from the middle, upload down from it. */
  function drawNet(hist) {
    const canvas = $("net-chart");
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const w = canvas.width;
    const h = canvas.height;
    ctx.clearRect(0, 0, w, h);
    const mid = Math.round(h / 2);
    ctx.fillStyle = "rgba(139, 148, 158, 0.18)";
    ctx.fillRect(0, mid, w, 1);
    if (!hist || hist.rx.length === 0) return;
    let max = 1024;
    for (const v of hist.rx) if (v > max) max = v;
    for (const v of hist.tx) if (v > max) max = v;
    const step = w / HISTORY_LEN;
    const barW = Math.max(1, step - 1);
    const startX = w - hist.rx.length * step;
    const half = mid - 2;
    ctx.fillStyle = "#39c5bb";
    for (let i = 0; i < hist.rx.length; i++) {
      const bh = (hist.rx[i] / max) * half;
      if (bh > 0.5) ctx.fillRect(startX + i * step, mid - bh, barW, bh);
    }
    ctx.fillStyle = "#a371f7";
    for (let i = 0; i < hist.tx.length; i++) {
      const bh = (hist.tx[i] / max) * half;
      if (bh > 0.5) ctx.fillRect(startX + i * step, mid + 1, barW, bh);
    }
  }

  // Sample Execution
  let sampling = false;
  async function performSample() {
    if (!window.oriel || !window.oriel.invoke) {
      elFooterStatus.textContent = "Running in browser preview (Oriel IPC unavailable)";
      return;
    }
    // One in flight at a time: a slow sample (a drive's sensor waking up)
    // doesn't pile calls up behind it.
    if (sampling) return;
    sampling = true;
    try {
      const sample = await window.oriel.invoke("sample");
      if (!sample) return;

      lastSampleData = sample;
      applySample(sample);
    } catch (err) {
      console.error("Sample failed:", err);
      elHeaderStatus.textContent = `Sample error: ${err.message || err}`;
    } finally {
      sampling = false;
    }
  }

  /** A sample onto the page; `redraw`: the last one again (a part shown,
   *  a resize), its values already in the histories. */
  function applySample(sample, redraw = false) {
    const now = new Date();
    const totalCount = sample.total_processes || sample.processes.length || 0;
    if (!redraw) recordHistory(sample, totalCount);

    // Engine & latency badges
    if (sample.sample_time_ms != null) setText(elPerfBadge, `⚡ ${sample.sample_time_ms.toFixed(2)} ms`);
    if (sample.engine) setText(elFooterEngine, sample.engine);

    if (shown("tiles")) applyTiles(sample, totalCount);
    if (shown("system")) setText($("sys-boot"), bootTime());
    if (shown("cpu")) applyCpu(sample);
    if (shown("mem")) applyMem(sample.mem);
    if (shown("disks")) applyDisks(sample.disks || []);
    if (shown("net")) applyNet(sample.net || []);
    if (!redraw && !(sample.sensors || []).length && !unavailable.has("sensors")) {
      unavailable.add("sensors");
      applySettings();
    }
    if (shown("sensors")) applySensors(sample.sensors || []);

    setText(elHeaderStatus, samplingActive
      ? `Sampling every ${settings.interval / 1000}s · Last sample at ${formatClock(now)}`
      : `Sampling paused · Last sample at ${formatClock(now)}`);

    if (shown("proc")) renderTable();
  }

  // Histories always grow (a part shown later has its past); drawing only
  // happens for what's shown.
  function recordHistory(sample, totalCount) {
    const cpu = sample.cpu;
    pushHistory(cpuHistory, cpu.percent || 0);
    pushHistory(userHistory, cpu.user_percent || 0);
    pushHistory(systemHistory, cpu.system_percent || 0);
    pushHistory(iowaitHistory, cpu.iowait_percent || 0);
    pushHistory(memHistory, sample.mem.percent || 0);
    pushHistory(procHistory, totalCount);
    const cores = cpu.per_core || [];
    for (let i = 0; i < cores.length; i++) {
      if (!coreHistory[i]) coreHistory[i] = [];
      pushHistory(coreHistory[i], cores[i].percent);
    }
    for (const n of sample.net || []) {
      let hist = netHistory.get(n.name);
      if (!hist) netHistory.set(n.name, (hist = { rx: [], tx: [] }));
      pushHistory(hist.rx, n.rx_bps);
      pushHistory(hist.tx, n.tx_bps);
    }
    lastUptime = sample.uptime_seconds || 0;
  }

  function applyTiles(sample, totalCount) {
    const cpu = sample.cpu;
    const mem = sample.mem;
    setText(elCpuValue, `${(cpu.percent || 0).toFixed(1)}%`);
    const cleanModel = cpu.model ? cpu.model.replace(/Processor|\d+-Core/gi, "").trim() : "Host CPU";
    setText(elCpuDetail, `${cpu.cores} cores · ${cleanModel}`);
    drawSparkline($("cpu-chart"), cpuHistory, 0, 100, "#39c5bb", false);

    setText(elMemValue, `${(mem.percent || 0).toFixed(1)}%`);
    setText(elMemDetail, `${formatBytes(mem.used_bytes)} / ${formatBytes(mem.total_bytes)}`);
    drawSparkline($("mem-chart"), memHistory, 0, 100, "#58a6ff", false);

    setText(elProcValue, String(totalCount));
    setText(elProcDetail, `${sample.threads_total || 0} threads`);
    const minProcs = Math.min(...procHistory) * 0.9;
    const maxProcs = Math.max(...procHistory) * 1.1;
    drawSparkline($("proc-chart"), procHistory, minProcs, maxProcs, "#39c5bb", true);

    setText(elUptimeValue, formatUptime(sample.uptime_seconds));
  }

  function bootTime() {
    if (!lastUptime) return "--";
    const d = new Date(Date.now() - lastUptime * 1000);
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())} (${formatUptime(lastUptime)} ago)`;
  }

  // CPU details: one row per core, made once.
  const coreRows = [];

  function buildCores(count) {
    elCoreGrid.textContent = "";
    coreRows.length = 0;
    setClass(elCoreGrid, "one-col", count <= 8);
    setClass(elCoreGrid, "four-col", count > 32);
    for (let i = 0; i < count; i++) {
      const row = document.createElement("div");
      row.className = "core-row";
      const label = document.createElement("span");
      label.className = "core-label";
      label.textContent = `C${i}`;
      const canvas = document.createElement("canvas");
      canvas.className = "core-chart";
      canvas.width = 120;
      canvas.height = 14;
      const pct = document.createElement("span");
      pct.className = "core-pct";
      const freq = document.createElement("span");
      freq.className = "core-freq";
      row.append(label, canvas, pct, freq);
      elCoreGrid.appendChild(row);
      coreRows.push({ canvas, pct, freq });
    }
    requestAnimationFrame(fitCanvases);
  }

  function applyCpu(sample) {
    const cpu = sample.cpu;
    const cores = cpu.per_core || [];
    if (coreRows.length !== cores.length) buildCores(cores.length);
    setText($("cpu-model"), cpu.model || "Host CPU");
    setText($("cpu-freq"), formatGhz(cpu.freq_mhz));
    const temp = $("cpu-temp");
    if (cpu.temp_c != null) {
      setText(temp, `${Math.round(cpu.temp_c)}°C`);
      setClass(temp, "hot", cpu.temp_c >= 75 && cpu.temp_c < 90);
      setClass(temp, "critical", cpu.temp_c >= 90);
    } else setText(temp, "--°C");
    const la = cpu.load_avg || [0, 0, 0];
    // No load average on Windows, no iowait on Windows or macOS.
    setClass($("cpu-load"), "hidden", !cpu.load_avg);
    if (cpu.load_avg) setText($("cpu-load"), `Load ${la.map((v) => v.toFixed(2)).join(" ")}`);
    setClass($("cpu-iowait").parentNode, "hidden", cpu.iowait_percent == null);
    setText($("cpu-tasks"), `${sample.running || 0} running · ${sample.threads_total || 0} threads`);
    setText($("cpu-user"), `${(cpu.user_percent || 0).toFixed(1)}%`);
    setText($("cpu-system"), `${(cpu.system_percent || 0).toFixed(1)}%`);
    setText($("cpu-iowait"), `${(cpu.iowait_percent || 0).toFixed(1)}%`);
    drawCpuStack();
    for (let i = 0; i < coreRows.length; i++) {
      const r = coreRows[i];
      const c = cores[i];
      setText(r.pct, `${Math.round(c.percent)}%`);
      setText(r.freq, c.freq_mhz > 0 ? `${(c.freq_mhz / 1000).toFixed(1)}G` : "");
      const busy = c.percent >= 80 ? "#f85149" : c.percent >= 50 ? "#d29922" : "#39c5bb";
      drawSparkline(r.canvas, coreHistory[i], 0, 100, busy, false);
    }
  }

  function applyMem(mem) {
    const total = mem.total_bytes || 1;
    setText($("mem-total"), `${formatBytes(mem.total_bytes)} total`);
    const meter = (id, bytes, whole, pctLabel = true) => {
      const el = $(id);
      const p = whole > 0 ? (bytes / whole) * 100 : 0;
      setText(el.querySelector(".meter-val"), pctLabel ? `${formatBytes(bytes)} · ${Math.round(p)}%` : formatBytes(bytes));
      setFill(el.querySelector(".fill"), p);
    };
    meter("m-used", mem.used_bytes, total);
    meter("m-avail", mem.available_bytes, total);
    meter("m-cached", mem.cached_bytes, total);
    meter("m-free", mem.free_bytes, total);
    const swap = $("m-swap");
    if (mem.swap_total_bytes > 0) {
      const p = (mem.swap_used_bytes / mem.swap_total_bytes) * 100;
      setText(swap.querySelector(".meter-val"), `${formatBytes(mem.swap_used_bytes)} / ${formatBytes(mem.swap_total_bytes)}`);
      setFill(swap.querySelector(".fill"), p);
    } else {
      setText(swap.querySelector(".meter-val"), "none");
      setFill(swap.querySelector(".fill"), 0);
    }
  }

  // Disks: an item per mount, made again only when the mounts change.
  let diskKey = "";
  let diskItems = [];

  function applyDisks(disks) {
    const key = disks.map((d) => d.device + d.mount).join("|");
    if (key !== diskKey) {
      diskKey = key;
      elDiskList.textContent = "";
      diskItems = disks.map(() => {
        const item = document.createElement("div");
        item.className = "disk-item";
        item.innerHTML =
          '<div class="disk-top"><span class="disk-name"></span><span class="disk-size"></span></div>' +
          '<div class="bar"><div class="fill fill-violet"></div></div>' +
          '<div class="disk-sub"><span class="disk-mount"></span><span class="disk-rw"></span></div>';
        elDiskList.appendChild(item);
        return {
          name: item.querySelector(".disk-name"),
          size: item.querySelector(".disk-size"),
          fill: item.querySelector(".fill"),
          mount: item.querySelector(".disk-mount"),
          rw: item.querySelector(".disk-rw"),
        };
      });
    }
    let rd = 0;
    let wr = 0;
    disks.forEach((d, i) => {
      const it = diskItems[i];
      const p = d.total_bytes > 0 ? (d.used_bytes / d.total_bytes) * 100 : 0;
      setText(it.name, d.name);
      setText(it.size, `${formatBytes(d.used_bytes)} / ${formatBytes(d.total_bytes)}`);
      setFill(it.fill, p);
      setClass(it.fill, "fill-danger", p >= 90);
      setText(it.mount, `${d.mount} · ${d.fs}`);
      setText(it.rw, `R ${formatRate(d.read_bps)} · W ${formatRate(d.write_bps)}`);
      rd += d.read_bps;
      wr += d.write_bps;
    });
    setText($("disk-io"), `R ${formatRate(rd)} · W ${formatRate(wr)}`);
  }

  // Network: one interface at a time (‹ ›), the busiest up one by default.
  let netNames = [];

  function pickIface(nets) {
    if (settings.netIface && nets.some((n) => n.name === settings.netIface)) return settings.netIface;
    let best = null;
    for (const n of nets) if (n.up && (!best || n.rx_total > best.rx_total)) best = n;
    return (best || nets[0] || {}).name || null;
  }

  function applyNet(nets) {
    netNames = nets.map((n) => n.name);
    const name = pickIface(nets);
    const n = nets.find((x) => x.name === name);
    const el = $("net-iface");
    if (!n) {
      setText(el, "none");
      drawNet(null);
      return;
    }
    setText(el, n.name);
    setClass(el, "down", !n.up);
    const hist = netHistory.get(n.name);
    setText($("net-rx"), formatRate(n.rx_bps));
    setText($("net-tx"), formatRate(n.tx_bps));
    setText($("net-rx-top"), formatRate(Math.max(0, ...hist.rx)));
    setText($("net-tx-top"), formatRate(Math.max(0, ...hist.tx)));
    setText($("net-rx-total"), formatBytes(n.rx_total));
    setText($("net-tx-total"), formatBytes(n.tx_total));
    drawNet(hist);
  }

  function cycleIface(dir) {
    if (netNames.length === 0) return;
    const current = pickIface((lastSampleData && lastSampleData.net) || []);
    const i = Math.max(0, netNames.indexOf(current));
    settings.netIface = netNames[(i + dir + netNames.length) % netNames.length];
    saveSettings();
    if (lastSampleData) applyNet(lastSampleData.net || []);
  }

  // Sensors: a row each, made again only when the set changes.
  let sensorKey = "";
  let sensorRows = [];

  function applySensors(sensors) {
    const key = sensors.map((s) => s.name).join("|");
    if (key !== sensorKey) {
      sensorKey = key;
      elSensorList.textContent = "";
      sensorRows = sensors.map((s) => {
        const row = document.createElement("div");
        row.className = "sensor-row";
        const name = document.createElement("span");
        name.className = "sensor-name";
        name.textContent = s.name;
        const temp = document.createElement("span");
        temp.className = "sensor-temp";
        row.append(name, temp);
        elSensorList.appendChild(row);
        return { temp, cls: "" };
      });
      setText($("sensor-count"), `${sensors.length} sensors`);
    }
    sensors.forEach((s, i) => {
      const r = sensorRows[i];
      setText(r.temp, `${Math.round(s.temp_c)}°C`);
      const cls = tempClass(s.temp_c);
      if (cls !== r.cls) {
        if (r.cls) r.temp.classList.remove(r.cls);
        if (cls) r.temp.classList.add(cls);
        r.cls = cls;
      }
    });
  }

  function renderTable() {
    if (!lastSampleData || !lastSampleData.processes) return;

    let rows = [...lastSampleData.processes];

    // Filter
    if (filterText.trim().length > 0) {
      const q = filterText.trim().toLowerCase();
      rows = rows.filter((r) => {
        return String(r.pid).includes(q) ||
          (r.name && r.name.toLowerCase().includes(q)) ||
          (r.user && r.user.toLowerCase().includes(q)) ||
          (r.command && r.command.toLowerCase().includes(q));
      });
    }

    // Sort with robust tie-breaking
    rows.sort((a, b) => {
      let diff = 0;
      if (currentSortKey === "cpu") {
        diff = (a.cpu_percent - b.cpu_percent) || (a.mem_rss_bytes - b.mem_rss_bytes);
      } else if (currentSortKey === "mem") {
        diff = (a.mem_rss_bytes - b.mem_rss_bytes) || (a.cpu_percent - b.cpu_percent);
      } else if (currentSortKey === "threads") {
        diff = (a.threads - b.threads) || (a.cpu_percent - b.cpu_percent);
      } else if (currentSortKey === "pid") {
        diff = a.pid - b.pid;
      } else if (currentSortKey === "name") {
        diff = (a.name || "").localeCompare(b.name || "");
      }
      return sortAscending ? diff : -diff;
    });

    setText(elCountBadge, `${rows.length} of ${lastSampleData.total_processes}`);
    viewRows = rows;
    setClass(elEmptyState, "hidden", rows.length > 0);
    // The list is as tall as all its rows; only the ones in view exist.
    const height = `${rows.length * ROW_H}px`;
    if (elProcTbody.style.height !== height) elProcTbody.style.height = height;
    syncRows(true);
  }

  // The process list is virtual: rows are placed absolutely at their index,
  // and only those in view (and a few around) are in the page. A sample
  // updates those (~35, not 256); a scroll step adds the one or two rows
  // coming into view and drops those leaving, the others untouched.
  const ROW_H = 34;
  const ROW_SPARE = 6;
  const elTableScroll = $("table-scroll");
  let viewRows = [];
  let viewHeight = 0;
  const liveRows = new Map(); // index → row
  const freeRows = [];

  function syncRows(refresh) {
    if (!viewHeight) viewHeight = elTableScroll.clientHeight || 600;
    const top = elTableScroll.scrollTop || 0;
    const first = Math.max(0, Math.floor(top / ROW_H) - ROW_SPARE);
    const last = Math.min(viewRows.length, Math.ceil((top + viewHeight) / ROW_H) + ROW_SPARE);
    for (const [i, row] of liveRows) {
      if (i >= first && i < last) continue;
      row.el.remove();
      liveRows.delete(i);
      freeRows.push(row);
    }
    for (let i = first; i < last; i++) {
      let row = liveRows.get(i);
      if (row) {
        if (refresh) fillRow(row, viewRows[i]);
        continue;
      }
      row = freeRows.pop() || makeRow();
      row.el.style.top = `${i * ROW_H}px`;
      fillRow(row, viewRows[i]);
      liveRows.set(i, row);
      elProcTbody.appendChild(row.el);
    }
  }

  /** A row's cells to a process: only the text that changed is touched. */
  function fillRow(row, r) {
    row.proc = r;
    setText(row.cells.pid, String(r.pid));
    setText(row.cells.name, r.name || "unknown");
    setText(row.cells.user, r.user || "");
    setText(row.cells.state, r.state || "?");
    setText(row.cells.threads, String(r.threads || 1));
    setText(row.cells.cpu, `${r.cpu_percent.toFixed(1)}%`);
    setText(row.cells.mem, formatBytes(r.mem_rss_bytes));
    setText(row.cells.cmd, r.command || "");
  }

  elTableScroll.addEventListener("scroll", () => {
    if (viewRows.length) syncRows(false);
  });

  /** A table row with its cells and buttons; `proc` is the process it shows. */
  function makeRow() {
    const row = { el: document.createElement("div"), cells: {}, proc: null };
    row.el.className = "table-row";
    // Right-click context menu with submenus
    row.el.oncontextmenu = (e) => {
      if (row.proc) showContextMenu(e, row.proc);
    };
    // Tooltips name the row's current process. Set on hover, not on every
    // sample: an attribute change restyles its element.
    row.el.onmouseenter = () => {
      if (!row.proc) return;
      row.cells.name.title = row.proc.name || "";
      row.cells.cmd.title = row.proc.command || "";
      row.btnKill.title = `${closeLabel === "Close…" ? "Ask to close" : "Send SIGTERM to"} ${row.proc.name} (${row.proc.pid})`;
    };
    for (const [key, cls] of [["pid", "col-pid"], ["name", "col-name"], ["user", "col-user"], ["state", "col-state"], ["threads", "col-threads"], ["cpu", "col-cpu"], ["mem", "col-mem"], ["cmd", "col-cmd"]]) {
      const cell = document.createElement("div");
      cell.className = cls;
      row.cells[key] = cell;
      row.el.appendChild(cell);
    }
    const elActions = document.createElement("div");
    elActions.className = "col-actions";

    // Terminate Button
    row.btnKill = document.createElement("button");
    row.btnKill.className = "row-btn btn-kill-row";
    row.btnKill.textContent = closeLabel;
    row.btnKill.onclick = (e) => {
      e.stopPropagation();
      if (row.proc) openKillModal(row.proc.pid, row.proc.name);
    };

    // Copy Name Button
    const btnCopy = document.createElement("button");
    btnCopy.className = "row-btn";
    btnCopy.textContent = "Copy";
    btnCopy.title = "Copy process name";
    btnCopy.onclick = (e) => {
      e.stopPropagation();
      if (row.proc) copyText(row.proc.name, "process name");
    };

    elActions.appendChild(row.btnKill);
    elActions.appendChild(btnCopy);
    row.el.appendChild(elActions);
    return row;
  }

  // Settings: the parts shown, and the sampling interval.
  function applySettings() {
    for (const s of SECTIONS) setClass($(s.el), "hidden", !shown(s.key));
    // The panels row: as many columns as panels shown, gone when none is.
    const panels = PANEL_KEYS.filter(shown).length;
    const row = $("panels-row");
    setClass(row, "hidden", panels === 0);
    for (const n of [1, 2, 3]) setClass(row, `cols-${n}`, panels === n);
    // Three panels: the middle one two columns wide (style.css).
    const visible = PANEL_KEYS.filter(shown);
    for (const k of PANEL_KEYS) setClass($(SECTIONS.find((s) => s.key === k).el), "span-2", panels === 3 && k === visible[1]);
    // The processes fill what's left when they're nearly alone.
    const others = SECTIONS.filter((s) => s.key !== "proc" && s.key !== "tiles" && shown(s.key)).length;
    setClass($("sec-proc"), "fill", others === 0);
    setText(elCpuToggle, shown("cpu") ? "▾" : "▸");
    setText(elCadenceNote, `60 samples kept · ${settings.interval / 1000} s cadence`);
    for (const b of document.querySelectorAll("#interval-group .btn-toggle")) setClass(b, "active", Number(b.dataset.ms) === settings.interval);
    for (const r of settingRows) {
      setClass(r.sw, "on", shown(r.key));
      setClass(r.row, "unavailable", unavailable.has(r.key));
      setText(r.label, unavailable.has(r.key) ? `${r.text} (not on this OS)` : r.text);
    }
    // What was hidden is drawn now, from the last sample.
    requestAnimationFrame(() => {
      viewHeight = 0;
      fitCanvases();
      if (lastSampleData) applySample(lastSampleData, true);
    });
  }

  const settingRows = [];

  function buildSettings() {
    const list = $("settings-list");
    for (const s of SECTIONS) {
      const row = document.createElement("div");
      row.className = "setting-row";
      const label = document.createElement("span");
      label.textContent = s.label;
      const sw = document.createElement("div");
      sw.className = "switch";
      const knob = document.createElement("div");
      knob.className = "switch-knob";
      sw.appendChild(knob);
      row.append(label, sw);
      row.onclick = (e) => {
        e.stopPropagation();
        if (!unavailable.has(s.key)) toggleSection(s.key);
      };
      list.appendChild(row);
      settingRows.push({ key: s.key, sw, row, label, text: s.label });
    }
    for (const b of document.querySelectorAll("#interval-group .btn-toggle")) {
      b.onclick = (e) => {
        e.stopPropagation();
        settings.interval = Number(b.dataset.ms);
        saveSettings();
        if (samplingActive) startLoop();
        applySettings();
      };
    }
  }

  function toggleSection(key) {
    settings.show[key] = !shown(key);
    saveSettings();
    applySettings();
  }

  // Actions
  function toggleSampling() {
    samplingActive = !samplingActive;
    if (samplingActive) {
      elPauseIcon.textContent = "⏸";
      elPauseLabel.textContent = "Pause";
      elHeaderStatus.textContent = "Resuming sampling...";
      elStatusDot.classList.remove("paused");
      startLoop();
      performSample();
    } else {
      elPauseIcon.textContent = "▶";
      elPauseLabel.textContent = "Resume";
      elHeaderStatus.textContent = "Sampling paused";
      elStatusDot.classList.add("paused");
      stopLoop();
    }
  }

  function startLoop() {
    stopLoop();
    sampleTimer = setInterval(performSample, settings.interval);
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
          elFooterStatus.textContent = `${endVerb.done} ${name} (PID ${pid})`;
          performSample();
        } else {
          elFooterStatus.textContent = `${endVerb.failed} PID ${pid} (permission denied, exited, or no window)`;
        }
      } catch (err) {
        elFooterStatus.textContent = `Error terminating process: ${err}`;
      }
    }
  }

  // Event Listeners
  elBtnPause.onclick = toggleSampling;
  elBtnRefresh.onclick = performSample;

  $("tile-cpu").onclick = () => toggleSection("cpu");
  $("net-prev").onclick = (e) => {
    e.stopPropagation();
    cycleIface(-1);
  };
  $("net-next").onclick = (e) => {
    e.stopPropagation();
    cycleIface(1);
  };

  $("btn-settings").onclick = (e) => {
    e.stopPropagation();
    elSettings.classList.toggle("hidden");
  };
  elSettings.onclick = (e) => e.stopPropagation();

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
  document.querySelectorAll(".toolbar .sort-group .btn-toggle").forEach((btn) => {
    btn.onclick = () => {
      document.querySelectorAll(".toolbar .sort-group .btn-toggle").forEach((b) => b.classList.remove("active"));
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
  const onMenu = (id, fn) => {
    const el = $(id);
    if (!el) return;
    el.onclick = (e) => {
      e.stopPropagation();
      const row = contextTargetRow;
      hideContextMenu();
      if (row) fn(row);
    };
  };
  onMenu("ctx-terminate", (r) => openKillModal(r.pid, r.name));
  onMenu("ctx-copy-name", (r) => copyText(r.name, "process name"));
  onMenu("ctx-copy-pid", (r) => copyText(String(r.pid), "PID"));
  onMenu("ctx-copy-cmd", async (r) => {
    // Samples carry the first 200 bytes; the whole line is asked for.
    let cmd = r.command || r.name;
    try {
      const full = await window.oriel.invoke("command_line", { pid: r.pid });
      if (full) cmd = full;
    } catch (_) {}
    copyText(cmd, "command line");
  });
  onMenu("ctx-copy-line", (r) => copyText(`${r.pid}\t${r.name}\t${r.user}\t${r.cpu_percent.toFixed(1)}%\t${formatBytes(r.mem_rss_bytes)}\t${r.command}`, "row details"));
  onMenu("ctx-filter", (r) => {
    elSearchInput.value = r.name;
    filterText = r.name;
    elSearchClear.classList.remove("hidden");
    renderTable();
  });
  const ctxRefresh = $("ctx-refresh");
  if (ctxRefresh) {
    ctxRefresh.onclick = (e) => {
      e.stopPropagation();
      hideContextMenu();
      performSample();
    };
  }

  // Dismiss menus on click or escape
  window.addEventListener("click", () => {
    hideContextMenu();
    elSettings.classList.add("hidden");
  });
  window.addEventListener("contextmenu", (e) => {
    if (!e.target.closest("#proc-tbody .table-row")) {
      hideContextMenu();
    }
  });
  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      hideContextMenu();
      closeKillModal();
      elSettings.classList.add("hidden");
    }
  });
  let resizeQueued = false;
  window.addEventListener("resize", () => {
    if (resizeQueued) return;
    resizeQueued = true;
    requestAnimationFrame(() => {
      resizeQueued = false;
      viewHeight = 0;
      fitCanvases();
      if (lastSampleData) applySample(lastSampleData, true);
    });
  });

  // Modal actions
  elKillCancel.onclick = closeKillModal;
  elKillConfirm.onclick = confirmKill;
  elKillModal.onclick = (e) => {
    if (e.target === elKillModal) closeKillModal();
  };

  // Windows has no SIGTERM: terminate_process asks the app's windows to
  // close (WM_CLOSE), as their close buttons would.
  let endVerb = { done: "Sent SIGTERM to", failed: "Failed to send SIGTERM to" };
  let closeLabel = "Terminate…";
  function useWindowsWording() {
    endVerb = { done: "Asked to close:", failed: "No window to ask to close for" };
    closeLabel = "Close…";
    setText($("table-hint"), "Right-click or click Close… to ask an app to close (confirmed first)");
    setText($("ctx-terminate-label"), "Close (WM_CLOSE)…");
    setText($("kill-title"), "Ask to close?");
    setText($("kill-confirm"), "Ask to close");
    setText($("kill-subtext"), "Its windows are asked to close, as their close buttons would: the app can save its work or ask first. This monitor never force-kills.");
    for (const row of liveRows.values()) setText(row.btnKill, closeLabel);
    for (const row of freeRows) setText(row.btnKill, closeLabel);
  }

  // Initialize
  async function init() {
    buildSettings();
    applySettings();
    if (window.oriel && window.oriel.invoke) {
      try {
        const meta = await window.oriel.invoke("get_meta");
        if (meta) {
          if (meta.os === "windows") useWindowsWording();
          elEngineBadge.textContent = meta.native_ui ? "native_ui" : "WebView";
          if (!meta.native_ui) {
            elEngineBadge.className = "badge badge-secondary";
          }
        }
      } catch (_) {}
      try {
        const sys = await window.oriel.invoke("system_info");
        if (sys) {
          setText($("sys-host"), `${sys.hostname} · ${sys.arch}`);
          setText($("sys-os"), sys.os || "--");
          setText($("sys-kernel"), sys.kernel || "--");
          setText($("sys-board"), sys.board || "--");
          setText($("sys-bios"), sys.bios || "--");
          setText($("sys-cpu"), `${sys.cpu_model} · ${sys.threads} threads`);
        }
      } catch (_) {}
    }

    startLoop();
    performSample();
  }

  init();
})();
