# Memory-safety review: how to look

A read-only review procedure for Oriel's Zig code. Every finding needs a
**file:line**, a **concrete failure scenario** (inputs/sequence → what goes
wrong), a **severity** (critical/major/minor) and a **fix**. Mark it
**CONFIRMED** (traced in the code, or reproduced) or **PLAUSIBLE** (depends on
runtime conditions you did not reproduce). Don't report style issues.

Every bug class below has already happened in this repo once; the example is
the kind of thing to look for.

## 1. Leaks and double frees

- For every allocation (`alloc`, `create`, `dupe`, `allocPrint`, `toOwnedSlice`,
  `readFileAlloc`, `ArrayList` growth): find its `free`/`destroy`/`deinit` on
  **every** path, including each `try` and early `return` in between. An
  allocation followed by a `try` needs an `errdefer`.
- For ownership transfers, the callee must not free what the caller frees too.
  *Seen:* `webkit_uri_scheme_response_set_http_headers` takes ownership of the
  headers; we unref'd them as well → crash.
- Tests must use `std.testing.allocator` so leaks fail them. Flag code paths no
  test reaches with that allocator (e.g. commands hard-wired to
  `smp_allocator`).
- `defer x.deinit()` after `x.toOwnedSlice()`: check it's still correct.

## 2. Ownership and lifetimes

- Who frees a returned slice? The doc comment must say, and callers must match.
- No pointer into stack memory, an arena, or a buffer that is freed or reset
  before the pointer is last used. Check `ArenaAllocator.reset`, `ArrayList`
  growth (invalidates pointers into it), and strings returned from C that die
  on the next call (e.g. `sqlite3_column_text`).
- **Structs never copied after something stores a pointer to them.** *Seen:*
  `WaylandInput.init` returned a `Globals` by value after registering a
  listener that pointed at the local copy.

## 3. Null and optionals

- Every `.?`, `orelse unreachable` and `@ptrCast` from an optional: can the value
  really never be null?
- C / GObject / Win32 returns: check the real contract (the GIR file's
  `nullable`/`transfer-ownership` in `/usr/share/gir-1.0/*.gir`, the Win32 docs),
  not the generated binding. *Seen:* the bindings declared
  `webkit_web_view_get_uri` and `g_variant_lookup_value` non-null; both can
  return NULL.

## 4. Reference counting (GObject, GVariant, COM)

- One `unref`/`Release` per `ref`/`AddRef`/creation, on every path.
- GVariant: `g_variant_new_*` results are floating and consumed by containers
  and `g_dbus_method_invocation_return_value`; only unref what was `ref_sink`ed
  or returned owned (`get_child_value`).
- COM: `QueryInterface`/`get_*` returns are owned (`Release` them); handler
  objects we implement must count references correctly and not free
  themselves while WebView2 still holds them; `CoTaskMemFree` for strings
  WebView2 returns; `SysFreeString` for BSTRs.
- Win32 handles: `CloseHandle`, `DestroyWindow`, `DestroyMenu`, `DeleteObject`,
  `GlobalUnlock`/`GlobalFree` (unless ownership passed via `SetClipboardData`).

## 5. `undefined`, casts and integers

- Nothing `undefined` is read before it's written (arrays, out-parameters,
  structs filled by C).
- `@ptrCast`/`@alignCast`: the alignment and the pointee type must really
  match.
- `@intCast` and arithmetic on sizes that come from files, the network, C or the
  user: can it overflow or truncate? *Seen:* `u16 * u16` for icon sizes
  overflowed at 128 px and panicked.
- UTF-8 ↔ UTF-16 conversions: buffers sized correctly, NUL terminators present,
  results freed.

## 6. Threads

- Shared mutable state is protected (`std.Io.Mutex`) or atomic; no read after
  the lock is released of something another thread can free. *Seen:* the
  updater read a path under the lock, unlocked, then used it while another
  thread freed it.
- GTK/GLib UI and WebKit calls only on the main thread; Win32 windows, menus
  and COM objects only on the thread that owns them. Work from worker threads
  goes back via `g_idle_add` / posted messages.
- Callbacks and idle functions must not outlive the objects they point to.

## 7. Files, processes and sockets

- Every file, directory, socket and child process is closed or waited on
  exactly once, including error paths.
- Replacing files: temp file in the same directory, exclusive create, explicit
  mode, fsync the file and the directory, rename; no following a symlink an
  attacker controls.
- Child processes: killed and reaped if we give up on them; environment and
  arguments built without truncation.

## 8. Input from outside

- Everything from the network, the webview (IPC arguments), files, the
  clipboard and the command line is untrusted: bounds, size limits, path
  traversal (`..`, absolute paths, symlinks), integer parsing (digits only).

## How to run it

1. Work on a **read-only snapshot**: `git worktree add --detach <tmp> <commit>`
   so nothing in the repo changes while you read.
2. Scope with `git diff <base>..<commit> --stat`, then read every changed file
   fully, not just the diff hunks, so you see the surrounding ownership.
3. For each file, go through sections 1–8 in order.
4. Build and test the snapshot (`zig build check`, `zig build test`, and the
   `-Dtarget=x86_64-windows` check for Windows code) to confirm nothing is
   stale.
5. Report findings ranked by severity, plus a list of the sections you checked
   and found clean. Don't edit files; fixes are a separate task.
