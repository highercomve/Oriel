# Zig 0.16 cheat sheet (as used in Oriel)

Every form below compiles in this repo today (file references point at a
working use). Read this before grepping `~/.zvm/0.16.0/lib/std`: most of the
0.14/0.15 APIs you remember moved in 0.16, mainly into `std.Io`.

Zig binary: `~/.zvm/0.16.0/zig` (non-interactive shells don't run the zvm hook
and would get 0.15.2).

## Entry point, args, allocators

```zig
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;          // std.Io: pass it to anything that does I/O
    const gpa = init.gpa;        // general-purpose allocator
    const argv = init.minimal.args.vector;           // [][*:0]const u8
    const first = std.mem.span(argv[1]);
    // init.environ_map: environment for child processes
}
```

- Global allocator without an `init`: `std.heap.smp_allocator`
  (thread-safe; `.create`, `.destroy`, `.free`, `.dupe`).
- Arenas: `var a = std.heap.ArenaAllocator.init(gpa); defer a.deinit();`
- `std.ArrayList(T)` is unmanaged: `var l: std.ArrayList(T) = .empty;`,
  `try l.append(gpa, x)`, `l.deinit(gpa)`, `try l.toOwnedSlice(gpa)`.

## Files and directories (`std.Io.Dir`, every call takes `io`)

```zig
const cwd = std.Io.Dir.cwd();
var dir = try cwd.openDir(io, path, .{ .iterate = true }); defer dir.close(io);
const data = try cwd.readFileAlloc(io, path, gpa, .limited(1 << 20));
try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
try cwd.createDirPath(io, "a/b/c");
try src.copyFile(src_path, dest_dir, dest_path, io, .{});
var walker = try dir.walk(gpa); defer walker.deinit();
while (try walker.next(io)) |e| { if (e.kind == .file) use(e.path); }
```
See `tools/embed_assets.zig`, `src/oriel.zig` (`writeTypes`).

## Readers and writers (`std.Io.Reader` / `std.Io.Writer`)

```zig
var out: std.Io.Writer.Allocating = .init(gpa); defer out.deinit();
try out.writer.print("{s}\n", .{x});  const bytes = out.written();  // or toOwnedSlice()
var fixed: std.Io.Writer = .fixed(buf);  // then fixed.buffered()
var in: std.Io.Reader = .fixed(bytes);
```

## Formatting

`std.fmt.allocPrint(gpa, fmt, args)`, `allocPrintSentinel(gpa, fmt, args, 0)`
(for C strings), `bufPrint`, `bufPrintZ`, `bytesToHex(digest, .lower)`.

## JSON

```zig
const v = try std.json.parseFromSliceLeaky(T, arena, text, .{ .ignore_unknown_fields = true });
const v2 = try std.json.parseFromValueLeaky(T, arena, json_value, .{});
const text = try std.json.Stringify.valueAlloc(gpa, value, .{});
```
See `src/core/ipc.zig`.

## Threads, locks, sleeping

```zig
const t = try std.Thread.spawn(.{}, func, .{args});  t.join();
var m: std.Io.Mutex = .init;  var c: std.Io.Condition = .init;
m.lockUncancelable(io); defer m.unlock(io);
c.waitUncancelable(io, &m);  c.signal(io);  c.broadcast(io);
var n: std.atomic.Value(u32) = .init(0);  _ = n.fetchAdd(1, .monotonic);
try io.sleep(.fromMilliseconds(10), .awake);            // simplest sleep
```
- Mutex and Condition live in `std.Io` now and take `io`
  (`src/core/ThreadPool.zig`). There is no `std.Thread.Mutex` / `std.time.sleep`.
- Constants: `std.time.ns_per_ms`, `std.time.us_per_ms`.
- Without an `io` (e.g. inside C callbacks): `std.c.nanosleep(&ts, null)`
  (`src/plugins/input.zig`).

## Child processes

```zig
var child = try std.process.spawn(io, .{
    .argv = argv, .cwd = .{ .path = dir }, .environ_map = init.environ_map,
});
const term = try child.wait(io);
```
Signals: `std.posix.kill(pid, std.posix.SIG.TERM)`. `SIG` is an enum: pass
`@intFromEnum(std.posix.SIG.TERM)` where a C `int` is expected. See
`tools/dev_runner.zig`. In GTK code, prefer `gio.SubprocessLauncher`
(`src/core/App.zig`, `startDevServer`).

## HTTP, crypto, compression

```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io }; defer client.deinit();
var body: std.Io.Writer.Allocating = .init(gpa); defer body.deinit();
const r = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });

const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
const sig = try kp.sign(msg, null);  try sig.verify(msg, kp.public_key);
std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});

var window: [std.compress.flate.max_window_len]u8 = undefined;
var d: std.compress.flate.Decompress = .init(&reader, .gzip, &window);
const out = try d.reader.allocRemaining(gpa, .unlimited);
```
See `src/modules/media_server.zig`, `src/modules/updater.zig`.

## URLs

`std.Uri.parse(url)`; host buffer size is `std.Io.net.HostName.max_len`
(not `std.Uri.host_name_max`). See `src/core/security.zig`.

## Linux syscalls

`std.os.linux.inotify_init1`, `inotify_add_watch`, `read`, `prctl`,
`getpid`; check results with `std.os.linux.errno(rc)`
(`src/modules/fs_watch.zig`). `std.posix.memfd_create(name, 0)` for the
virtual-keyboard keymap.

## C interop and linking

- `@cImport(@cInclude("..."))` still works (`src/modules/sql.zig`).
- Macros that are casts (e.g. `SQLITE_TRANSIENT`) don't translate: define
  them by hand.
- Executables and tests must link with `.use_llvm = true, .use_lld = true`
  (GCC 16 `crt1.o` has `.sframe` sections Zig's own linker rejects).

## Build system (`build.zig`)

- `b.graph.host` for build tools, `b.graph.io` for I/O in the build script.
- `run.addOutputDirectoryArg("name")` → a generated directory as a `LazyPath`.
- A new package's `build.zig.zon` needs `.fingerprint`; `zig build` prints the
  value to use. Renaming a package changes its fingerprint.
- Dependencies unpack into a project-local `zig-pkg/` (git-ignored).
