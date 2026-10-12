<!-- Generated from site/content/docs/paths.smd by tools/docs/gen-md.mjs: edit that file. -->

# App directories

The app's own directories on every platform, from one call each: oriel.paths.appData, appCache, appConfig and appExternal.

`oriel.paths` answers "where does this app keep its files?" on every
platform with one call and no `if (android)`: `appData` for what the app
must not lose (databases, documents it manages), `appCache` for what it can
fetch or rebuild (thumbnails, responses), `appConfig` for settings files,
and `appExternal` for large files the user (or `adb`) should reach, such as
downloaded models. It is the one place Oriel and apps get these folders
from: the [settings store](store.md) keeps its JSON files
in `appConfig`.

Use `appData` for files; small settings fit the store. Files the user picks
or saves elsewhere go through [dialogs](dialogs.md) and
[files](files.md).

## Availability

| Platform | `appData` (kept until the app is removed) | `appCache` (the system may clear it) |
|---|---|---|
| Linux | `$XDG_DATA_HOME/<name>` (`~/.local/share/<name>`) | `$XDG_CACHE_HOME/<name>` (`~/.cache/<name>`) |
| Windows | `%LOCALAPPDATA%\<name>` | `%LOCALAPPDATA%\<name>\cache` |
| macOS | `~/Library/Application Support/<name>` | `~/Library/Caches/<name>` |
| iOS | `<container>/Library/Application Support/<name>` | `<container>/Library/Caches/<name>` |
| Android | the files dir itself (`Context.getFilesDir()`, `/data/user/0/<package>/files`) | the cache dir itself (`Context.getCacheDir()`) |

| Platform | `appConfig` (settings) | `appExternal` (large files the user can reach) |
|---|---|---|
| Linux | `$XDG_CONFIG_HOME/<name>` (`~/.config/<name>`) | the same as `appData` |
| Windows | `%APPDATA%\<name>` (roams with the profile) | the same as `appData` |
| macOS | the same as `appData` | the same as `appData` |
| iOS | the same as `appData` | the same as `appData` |
| Android | the same as `appData` | the app-specific external storage itself (`Context.getExternalFilesDir(null)`, `/storage/emulated/0/Android/data/<package>/files`), or the files dir when there is none |

`oriel.paths` is part of Oriel's core: always built, no flag, no
permission.

## Quick start

```zig
const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");

fn setup() !void {
    const gpa = std.heap.smp_allocator;
    const data = try oriel.paths.appData(gpa, .{ .name = "GhostPantry" });
    defer gpa.free(data);
    const db_path = try std.fs.path.join(gpa, &.{ data, "pantry.db" });
    defer gpa.free(db_path);
    std.log.info("database at {s}", .{db_path});
}

pub fn main(init: std.process.Init) !u8 {
    return oriel.main(init, .{ .commands = struct {}, .events = struct {} }, .{
        .app = app.build,
        .window = .{ .title = "GhostPantry" },
        .setup = setup,
    });
}
```

`name` is the folder's name off Android: the product name
(`"GhostPantry"`) or the app id (`app.build.id`). Pick one and keep it:
changing it moves the app's data to a new, empty folder.

## How it works

```mermaid
flowchart LR
  App["appData / appCache /<br/>appConfig / appExternal<br/>(name)"] -->|"validate name"| Check{"target"}
  Check -->|"Linux"| GLib["GLib: g_get_user_data_dir /<br/>cache_dir / config_dir"]
  Check -->|"Windows"| KF["SHGetKnownFolderPath<br/>(LocalAppData, RoamingAppData)"]
  Check -->|"macOS, iOS"| Home["$HOME/Library/..."]
  Check -->|"Android"| Rt["dirs the Kotlin runtime<br/>handed over before main"]
  GLib -->|"append /name, mkdir -p"| Out["path (caller frees)"]
  KF -->|"append the name, mkdir"| Out
  Home -->|"append /name, mkdir -p"| Out
  Rt -->|"as is, mkdir -p"| Out
```

`src/core/paths.zig` checks `name`, then asks the platform for its base
directory:

- **Linux** (`src/core/paths/linux.zig`): GLib's XDG base directories,
  which follow `$XDG_DATA_HOME`, `$XDG_CACHE_HOME` and `$XDG_CONFIG_HOME`.
- **Windows** (`paths/windows.zig`): the known folders Local AppData and,
  for `appConfig`, Roaming AppData.
- **macOS** and **iOS** (`paths/apple.zig`): `$HOME/Library/Application
  Support` and `$HOME/Library/Caches`. On iOS `$HOME` is the app's sandbox
  container.
- **Android** uses the directories the Kotlin runtime passes to native code
  at start, before the app's `main` (`src/platform/android/paths.zig`). The
  sandbox is already the app's own, so `name` adds no folder: the files sit
  in `filesDir` like a plain Android app's. `name` is still checked, so a
  bad name fails on every platform.

The directory is created if missing (GLib's `g_mkdir_with_parents` on
Linux, `mkdir -p` on the other POSIX targets, each level with
`CreateDirectoryW` on Windows). The call does file system work: call it
once, at start or in `setup`, and keep the path.

**Windows** uses Local AppData, not Roaming, for `appData`: databases and
models are large and machine-local and shouldn't roam with the profile.
Settings meant to roam belong in `appConfig` (`%APPDATA%`), where the store
keeps its files.

## Examples

### Open a database in the app's data folder

```zig
fn openDb(gpa: std.mem.Allocator) !oriel.sql.Db {
    const dir = try oriel.paths.appData(gpa, .{ .name = app.build.id });
    defer gpa.free(dir);
    const path = try std.fs.path.joinZ(gpa, &.{ dir, "notes.db" });
    defer gpa.free(path);
    return oriel.sql.Db.open(path);
}
```

See [SQL](sql.md) for the database API.

### A cache that may disappear

```zig
fn thumbnailPath(gpa: std.mem.Allocator, id: u64) ![]u8 {
    const cache = try oriel.paths.appCache(gpa, .{ .name = app.build.id });
    defer gpa.free(cache);
    return std.fmt.allocPrint(gpa, "{s}" ++ std.fs.path.sep_str ++ "{x}.jpg", .{ cache, id });
}
```

Treat a missing file in the cache as "rebuild it": phones clear caches on
low storage, and the user can clear them in the system settings.

### Show the user where their data is

```zig
pub const Commands = struct {
    /// invoke("data_folder"): for an "Open data folder" menu item.
    pub fn data_folder(gpa: std.mem.Allocator) ![]const u8 {
        return oriel.paths.appData(gpa, .{ .name = app.build.id });
    }
};
```

The page gets paths only through commands like this one; `oriel.paths` has
no page API.

### Downloaded models adb can reach

```zig
const dir = try oriel.paths.appExternal(gpa, .{ .name = app.build.id });
defer gpa.free(dir);
const models = try std.fs.path.join(gpa, &.{ dir, "models" });
defer gpa.free(models);
```

On Android that is `/sdcard/Android/data/<package>/files/models`, which
`adb push` can write to; elsewhere it is under `appData`. The showcase keeps
its whisper, LLM and voice models there (`examples/showcase/src/main.zig`).

## Reference

### `oriel.paths`

```zig
pub const Options = struct {
    name: []const u8,
};

pub fn appData(gpa: std.mem.Allocator, options: Options) ![]const u8;
pub fn appCache(gpa: std.mem.Allocator, options: Options) ![]const u8;
pub fn appConfig(gpa: std.mem.Allocator, options: Options) ![]const u8;
pub fn appExternal(gpa: std.mem.Allocator, options: Options) ![]const u8;
```

| Declaration | Meaning |
|---|---|
| `appData(gpa, .{ .name })` | The private data directory (the Availability tables), created if missing. Caller frees. |
| `appCache(gpa, .{ .name })` | The private cache directory, created if missing. Caller frees. |
| `appConfig(gpa, .{ .name })` | The settings directory (the store's files), created if missing. Caller frees. |
| `appExternal(gpa, .{ .name })` | The directory for large files the user can reach, created if missing. Caller frees. |
| `Options.name` | The folder name off Android. Checked everywhere: not empty (`error.EmptyAppId`); no `/`, `\`, `:`, `..`, NUL or control characters (`error.InvalidAppId`). |

**Errors.** `error.EmptyAppId`, `error.InvalidAppId`; allocation failures;
Android `error.AppNotRunning` before the runtime handed over its
directories (it does so before `main`, so this happens only in code that
runs before the runtime starts, such as tests);
`error.CreateDirectoryFailed` everywhere; macOS and iOS
`error.HomeNotSet`; Windows `error.KnownFolderNotFound`.

**Threads.** Any thread. Nothing is cached: each call queries the platform
and creates the directory.

### Other folders the app has

| Folder | Where |
|---|---|
| The store's settings files | `appConfig`; on Android its `<app id>` folder ([Settings store](store.md#directories)) |
| Log file | [Logging](logging.md) |

### Migrating from 0.11

- `appDir(gpa, kind, options)` and `Kind` are gone: call `appData` or
  `appCache`.
- `oriel.store.configDir` / `dataDir` / `cacheDir` are gone: use
  `appConfig` / `appData` / `appCache`. On Android the store's were
  `<filesDir>/<app id>` and `<cacheDir>/<app id>`; `appData` and
  `appCache` are the files and cache dirs themselves, so move files kept
  in the `<app id>` folder (or keep joining it yourself).
- `oriel.store.impl.externalDataDir` and `oriel.android.paths` are gone:
  use `appExternal` (the external files dir itself, no `<app id>` folder),
  `appData` and `appCache`.

## Troubleshooting

- **`InvalidAppId`.** `name` has a separator, `..`, `:` or a control
  character. Use a plain product name or the reverse-DNS app id.
- **Data "vanished" after renaming the app.** `name` changed, so the
  folder did; move the old folder or keep the old name.
- **Files in `appCache` are gone.** The system cleared it (phones, low
  disk, macOS storage management). Only keep there what can be rebuilt.

## Related

- [Settings store](store.md): settings by key, in
  `appConfig`.
- [SQL](sql.md): databases in `appData`.
- [Logging](logging.md): where the log file goes.
- [Files](files.md): files the user picks.
