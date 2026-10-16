# Oriel System Monitor

Live CPU, memory, and process monitor with three renderer modes: **WebView**, **native web** (JavaScript and native elements), and **Oriel** (compiled `.oriel` views and Zig, without JavaScript).


## Run the Oriel renderer

```sh
cd examples/system-monitor
zig build -Doptimize=ReleaseSafe
./zig-out/bin/oriel-system-monitor
```

The Oriel renderer is the default (and what the release packages use);
`-Drenderer=native` and `-Drenderer=webview` select the other modes. All three use the same platform sampler and process commands.

The Oriel frontend lives in [views/](views/) and
[oriel_monitor.zig](src/oriel_monitor.zig). It includes the summary tiles, system
information, 60-sample CPU/per-core histories, memory bars, disks, interface
selection and network graphs, sensors, process filtering/sorting, pause/refresh,
clipboard actions and confirmed process shutdown. It mounts at most 32 process
rows while scrolling through the busiest 256. Sampling runs on the existing
command pool with one request in flight; graphs redraw on samples and relevant
UI changes, with no continuous frame callback. When processes are the only
visible section, the table fills the available height.

**Applications** is the default list in all three renderers. It shows each
recognized desktop app's combined CPU, summed resident memory (RSS), threads,
and process count. **Show processes** opens that app's individual members as a
parent/child tree, like `ps --forest`. Sorting applies to roots and siblings,
keeping children under their parent. A missing or filtered parent leaves a
visible root rather than hiding its children;
**All processes** includes background services, command-line programs, and
system tasks. Searching and sorting work in both views, and the view preference
is saved. App totals include every readable member before the 256-row display
limit; an app with more members still reports its full total.

Grouping uses installed desktop entries plus parent processes on Linux,
the outer `.app` bundle plus ancestry on macOS, and visible top-level window
owners plus executable paths and ancestry on Windows. Ancestry alone does not
make an external command part of an app: unrecognized helpers must use the
same executable or live inside that app's installation directory (not shared
directories such as `/usr/bin` or Windows System32). Users stay separate,
and a nested recognized app keeps its own group. The grouping is best effort:
unreadable metadata and helpers whose app identity and ancestry are unavailable
remain in All processes. Shared pages may be counted more than once in summed
RSS; the number is not private or proportional memory. CPU uses the existing
per-process scale (100% is one core). Process shutdown still affects only the
chosen individual process, with confirmation.

Oriel settings are independent of the web frontends, persisted in
`oriel-settings.json` under `oriel.paths.appConfig` (Linux:
`~/.config/dev.oriel.SystemMonitor/`). Settings and process action panels scroll
in small windows. The confirmation focuses Cancel and covers background
controls; Enter cancels initially, Tab then Enter confirms. Escape closes
panels/dialogs. Windows uses the existing WM_CLOSE command.

```sh
zig build test -Doptimize=ReleaseFast
```

History and process-selection tests run with the command above. The new mode
was built and interactively checked on Linux/GTK: search/clear, sorting, table
scrolling, pause/manual refresh, persistent section/cadence settings, interface
selection, clipboard, narrow-window layout and keyboard confirmation. Shutdown
was checked against a disposable test process. Windows/macOS runtime behavior
and assistive technology still need platform validation; this remains an
experimental renderer. Existing performance tables below describe the native
web mode and do not measure this port.

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
- **Updates**: the header shows the version, and **Check for updates** (next
  to Settings) looks for a newer release with `oriel.updater`: then
  **Update to vX** downloads and installs it, and **Restart to update**
  runs it. See [Updates](#updates).

### Updates

The monitor ships with every Oriel release and has Oriel's version
(`build.zig.zon`, bumped with each release; the release job refuses a tag
that doesn't match). Each release attaches a signed
`system-monitor-latest.json` (Ed25519, Oriel's release key; the public key
is in `build.zig`), and a copy updates from its own entry, so it stays the
same kind of build (`src/updates.zig`):

| Installed as | Manifest entry | Update |
|---|---|---|
| An executable (e.g. in `~/.local/bin`) | `<arch>-<os>-<renderer>` (`-exe` on macOS) | Replaced, then restarted |
| The AppImage | `x86_64-linux-appimage-oriel` | The AppImage is replaced |
| The macOS `.app` | `aarch64-macos-oriel` | The bundle is swapped |
| A `.deb` or `.rpm` (`/usr`, `/opt`) | | Says a new version is out: update with the package manager |

The packages (AppImage, deb, rpm, Windows installer and zip, macOS `.app`)
use the Oriel renderer, the default; the native renderer's executables are
published too, so a native build updates to a native build. The webview
renderer isn't published, so its check says no update exists for it. `ORIEL_MONITOR_UPDATE_MANIFEST=<https url>` checks another
manifest (a release's own `system-monitor-latest.json` before it's the
latest); signatures are still checked against the built-in key.

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
- **`app_version`**: the version, renderer, how this copy was installed and whether it can update itself.
- **`update_check`**, **`update_install`**, **`update_restart`**: Check for updates (`src/updates.zig`); `update_install` reports progress as `monitor://update-progress`.

---

## How to Run with Oriel Commands

Use the `oriel` CLI commands from inside `examples/system-monitor`:

### Run with the Oriel Renderer (the default, zero WebView)

```bash
cd examples/system-monitor
oriel run
```

### Run with the Native UI Renderer (the page's JavaScript, zero WebView)

```bash
cd examples/system-monitor
oriel run -Drenderer=native
```

### Run with the System WebView

```bash
cd examples/system-monitor
oriel run -Drenderer=webview
```

### Dev Mode (Hot Reload)

```bash
oriel dev
```

### Check & Build

```bash
oriel check                      # Type-check without building binaries (~1 s)
oriel build                      # Build release binary into zig-out/bin/
```

