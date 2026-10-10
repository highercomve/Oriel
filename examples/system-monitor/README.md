# Oriel System Monitor

Live CPU, memory, and process monitor built in **Zig + Oriel**, running either with the system WebView or the experimental **native renderer** (`-Dnative_ui`).

Inspired by `native/examples/system-monitor/`, this version takes full advantage of Oriel's architecture: native compiled Zig telemetry on the backend and Oriel's high-performance native DOM and widget pipeline on the frontend.

---

## How the two compare

Measured on one Linux machine (Ryzen 7 7800X3D, RTX 4070, Hyprland, 787
processes), both built `ReleaseFast`; the full method and the CPU, thread
and size numbers are on the [comparison page](https://highercomve.github.io/Oriel/docs/comparison/).

| Metric / Mechanism | Native SDK (`native/examples/system-monitor`) | Oriel (`oriel/examples/system-monitor`) |
|---|---|---|
| **Telemetry Collection** | Spawns external processes (`ps axo pid=,pcpu=,pmem=,rss=,etime=,comm=` + `vm_stat`/`sysctl`) on every 2s tick | **Direct Linux `/proc` reads in Zig**: opens `/proc/stat`, `/proc/meminfo`, `/proc/uptime`, and iterates `/proc/[pid]/stat` directly |
| **Subprocess Overhead** | `fork()`, `execve("ps")`, dynamic linker, stdout pipe IPC, context switches | **0 subprocess spawns**; direct kernel procfs filesystem reads in pure Zig |
| **Collection Latency** | 18.9 ms per sample (`ps` + `cat`, run from a shell) | **6.0 ms** per sample (about 3× faster) |
| **Data Parsing** | Pure byte-slicing and binary long-division in TypeScript subset | Compiled native Zig structs, registers, in-place sorting (`std.mem.sort`) |
| **Rendering** | Native SDK layout compiler | **Oriel `native_ui`**: QuickJS bytecode + Oriel Native DOM (Zig store) + Yoga flexbox + GTK4/Cairo / Direct2D |
| **Process Termination** | Spawns `/bin/kill -TERM <pid>` | Direct `std.posix.kill(pid, SIG.TERM)` syscall in Zig |
| **Memory Footprint** | 233 MB RSS, 154 MB PSS | 178–184 MB RSS, 108–121 MB PSS (native_ui, Oriel 0.9.11) |
| **CPU** | 5.6% of one core | 1.1–2.5% of one core (256 rows updated in place) |

---

## Features

Every part below can be shown or hidden from **Settings** (⚙ in the header),
along with the sampling interval (1, 2 or 5 s). The choice is kept in
`localStorage`, which the native renderer saves under
`~/.config/dev.oriel.SystemMonitor/data/`. Hidden parts cost nothing: they
aren't updated or drawn.

- **Summary tiles**: CPU, memory, processes (and threads), uptime, each with
  a 60-sample sparkline. A click on the CPU tile opens or closes the CPU details.
- **System**: host, OS, kernel, board, BIOS, CPU, boot time.
- **CPU details** (like btop's): the total as user / system / iowait stacked
  over the last 60 samples, and a row per core with its own history,
  usage and current frequency; package temperature, load average, threads
  running and total.
- **Memory**: used, available, cached, free and swap, as bars.
- **Disks**: each mounted block device with its size, use and read/write rates.
- **Network**: download and upload rates mirrored on one graph, peaks and
  totals; ‹ › switches interface (the busiest one first).
- **Sensors**: every hwmon temperature (CPU, GPU, drives, board).
- **Processes**: PID, name, user, state, threads, CPU %, memory and command
  line for the 256 busiest; filter by name, user, command or PID; sort by
  CPU, memory, threads, PID or name. Right-click or **Terminate…** sends a
  confirmed `SIGTERM` (never `SIGKILL`); copy the name, PID, whole command
  line or row.
- **Responsive**: a fullscreen window gives the cores four columns and the
  table the rest of the height; a narrow one stacks the panels.

### Platforms

The page is the same everywhere; a sampler per OS fills it
(`sampler.zig` picks one), and the page hides what an OS doesn't report:

| | Linux | Windows | macOS |
|---|---|---|---|
| Sampler | `sampler_linux.zig`: /proc, /sys | `sampler_windows.zig`: NT and Win32 calls (no WMI) | `sampler_macos.zig`: Mach, libproc, sysctl |
| CPU per core, frequency | ✓ ✓ | ✓ ✓ | ✓, frequency on Intel only |
| Load average, iowait | ✓ ✓ | — | load ✓, no iowait |
| Memory, swap | ✓ | ✓ (page file) | ✓ (as Activity Monitor) |
| Disks, I/O rates | ✓ ✓ | ✓ ✓ | ✓, no I/O rates yet |
| Network | ✓ | ✓ (hardware adapters) | ✓ |
| Sensors | ✓ (hwmon) | — | — |
| Processes: user, threads, command line | ✓ | ✓ (others' only as admin) | ✓ (root's only as root) |
| Ending a process | SIGTERM | WM_CLOSE to its windows | SIGTERM |

`.github/workflows/system-monitor.yml` runs each sampler's test on its OS
and builds the packages: `.deb`, `.rpm`, `.AppImage`; an NSIS `setup.exe`
and a zip; a `.dmg` (unsigned).

### What it costs

Measured on the machine above (16 threads, ~500 processes), sampling every
second with every part shown, each monitor visible on screen:

| Monitor | CPU (of one core) | Memory (RSS) |
|---|---|---|
| **Oriel System Monitor** (`native_ui`) | **1.4%** | **174 MB** |
| btop, and the terminal drawing it | 2.5% | 401 MB |
| dgop, and the terminal drawing it | 17.8% | 326 MB |

How it stays cheap:

- **The sampler** (`sampler.zig`) reads /proc and /sys straight from Zig,
  no subprocesses: ~1.6 ms a sample. Each process's `/proc/<pid>/stat`
  stays open and is read again with `pread`; a process's name, command line
  and user (one `statx`) are read once while it lives; the mounts every 15
  samples. Sensors that cost a firmware call (ACPI, WMI) are read every 5th
  sample, a drive's (a command to the drive, which can wake it) every 15th.
- **The process table is virtual**: only the rows in view exist, so a
  sample updates ~35 rows, not 256, and a scroll step adds or drops one.
- **Only what changed is touched**: texts are set when they differ, bars
  when their whole percentage does; numbers arrive rounded, command lines
  cut at 200 bytes (copying asks for the whole).

---

## Oriel IPC Commands

The frontend communicates with the backend strictly through typed Oriel commands via `window.oriel.invoke`:

- **`sample`**: every interval (or on Refresh): CPU (total, per core,
  frequencies, temperature, load), memory, disks, network, sensors and the
  busiest processes.
- **`system_info`**: the static description (host, OS, kernel, board, BIOS), once.
- **`command_line`**: `{ pid }`: a process's whole command line.
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

