# Oriel Comprehensive Security & Memory Safety Review

**Date**: 2026-10-08  
**Scope**: Full codebase audit across Memory Allocations, Concurrency & Threading, IPC & Webview Bridges, Custom URI Schemes, File Operations, and the Auto-Updater.  
**Platform Coverage**: Linux (WebKitGTK / GTK4), Windows (WebView2 / Win32), macOS (WKWebView / AppKit), Android (android.webkit.WebView / JNI), iOS (WKWebView / UIKit).

---

## Executive Summary Matrix

| ID | Severity | Status | Location | Bug Class | Vulnerability Summary |
|:---|:---|:---|:---|:---|:---|
| **MEM-01** | **CRITICAL** | **CONFIRMED** | `src/platform/linux/bridge.zig:649-670` | Use-After-Free / Use-After-Unref | Accessing `WebKitScriptMessageReply` after dropping reference on OOM/dispatch error paths. |
| **CONC-01** | **CRITICAL** | **CONFIRMED** | `src/core/file_handles.zig:98-185` | Concurrency / Use-After-Free | Unsynchronized `FileHandles` table causing data race and descriptor hijacking across threads. |
| **CONC-02** | **CRITICAL** | **CONFIRMED** | `src/core/App.zig:864-872`, `ThreadPool.zig:57-69` | Concurrency / Use-After-Free | `worker_pool` destroyed prior to pointer nullification; post-shutdown task loss and memory leak. |
| **SEC-01** | **CRITICAL** | **CONFIRMED** | `src/modules/share/apple.zig:88-104` | Path Traversal / Arbitrary Deletion | `removeCopy` substring match permits `..` traversal out of `/Documents/Inbox/` to delete files. |
| **SEC-02** | **HIGH** | **CONFIRMED** | `src/platform/linux/bridge.zig:625-640` | Origin Confusion / Privilege Escalation | Linux WebKitGTK bridge retrieves top-level URL rather than sender subframe origin. |
| **SEC-03** | **HIGH** | **CONFIRMED** | `src/core/isolation.zig:280-360` | Isolation Bypass / Cross-Origin Leak | `location.ancestorOrigins` is undefined on WebKit/Safari, bypassing origin checks and leaking via `postMessage("*")`. |
| **SEC-04** | **HIGH** | **CONFIRMED** | `src/core/ipc.zig:134-178` | Token Exposure | Bridge scripts statically embed `"local"` HMAC secret token into all webview documents and frames. |
| **CONC-03** | **HIGH** | **CONFIRMED** | `src/core/App.zig:478-489` | Concurrency / Use-After-Free | `ensureWindow` releases `windows_mutex` while holding raw slices into registered window strings. |
| **CONC-04** | **HIGH** | **CONFIRMED** | `src/core/ipc.zig:510-545` | Concurrency / Dangling Pointer | Async IPC error text points to worker thread-local `fail_buf`, read concurrently after thread reuse. |
| **DOS-01** | **HIGH** | **CONFIRMED** | `src/updater_core.zig:393-402, 474` | Denial of Service / Decompression Bomb | Uncapped disk streaming and `.unlimited` heap allocation during gzip update decompression. |
| **SEC-05** | **MEDIUM** | **CONFIRMED** | `src/core/window_commands.zig:100-115` | Privilege Escalation / Spoofing | `oriel:window:emitTo` completely omits `validateWindowModification` permissions check. |
| **SEC-06** | **MEDIUM** | **CONFIRMED** | `src/modules/updater/macos.zig:185-230` | Tar Path Traversal Bypass | `LinkGuard` ignores `std.tar.FileKind.hard_link` during `.app` bundle update extraction. |
| **SEC-07** | **MEDIUM** | **CONFIRMED** | `src/modules/model_download.zig:49-65` | SSRF / Cleartext Downgrade | Unchecked HTTP 301/302 redirects allow redirection to internal loopback addresses or HTTP. |
| **MEM-02** | **MEDIUM** | **CONFIRMED** | `src/core/ipc.zig:383-395` | Memory Leak | Up to 16 MiB heap payload leaked if `share:read` fails during base64 arena allocation. |
| **MEM-03** | **MEDIUM** | **CONFIRMED** | `src/platform/linux/scheme.zig:52`, `media_scheme/linux.zig:173` | Memory Leak | `SoupMessageHeaders` referenced by WebKitGTK is never unreferenced by the caller. |
| **MEM-04** | **MEDIUM** | **CONFIRMED** | `src/platform/linux/window.zig:360`, `windows/window.zig:1608` | Allocator Mismatch | Hardcoded `std.heap.smp_allocator` frees window structs allocated via `heap.gpa`. |
| **CONC-05** | **MEDIUM** | **CONFIRMED** | `src/modules/media_scheme/windows.zig:176-205` | Concurrency / Data Race | Speculative `fetchSub` offset rollback in Windows `FileWindowStream` corrupts concurrent reads. |
| **SEC-08** | **MEDIUM** | **CONFIRMED** | `src/modules/media_server.zig:33-70` | DNS Rebinding / Port Scanning | Missing `Host` header validation and `Access-Control-Allow-Origin: *` on local media streaming server. |
| **SEC-09** | **LOW-MEDIUM** | **CONFIRMED** | `src/updater_core.zig:220-225` | Replay Attack | Optional `expires` timestamp in manifests allows indefinite validity and rollback replays. |
| **MEM-05** | **LOW** | **CONFIRMED** | `src/platform/linux/dev_server.zig:23-28` | Memory Leak | `defer` statement declared after argument loop leaks earlier elements on allocation failure. |
| **BUG-01** | **LOW** | **CONFIRMED** | `src/modules/updater/linux.zig:44-48` | I/O Buffer Truncation | Single `readSliceShort` truncates Linux `/proc/self/cmdline` past 2048 bytes on restart. |

---

## Detailed Findings

### 1. Memory Safety & Lifecycle (Use-After-Free, Double-Free, Leaks)

#### [CRITICAL] MEM-01: Use-After-Free in Linux WebKit IPC Bridge
- **Location**: `src/platform/linux/bridge.zig:649-653` and `664-670`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. Frontend dispatches an async command via `window.webkit.messageHandlers.oriel.postMessage(...)`.
  2. In `onMessage`, references are incremented: `reply.ref()` and `context.ref()`.
  3. Memory allocation for `GtkReply` fails (`OutOfMemory`) or worker dispatch fails (`ipc.dispatchAsync` returns an error).
  4. The error handler calls `reply.unref()` and `context.unref()`. If the caller's reference was the sole remaining reference, the underlying GObject / WebKit structure is destroyed.
  5. Immediately following, the handler calls `reply.returnErrorMessage("OutOfMemory")` on the deallocated object, causing a segmentation fault or memory corruption.
- **Code Trace**:
  ```zig
  // src/platform/linux/bridge.zig:649
  const gtk_reply = std.heap.smp_allocator.create(GtkReply) catch {
      reply.unref();
      context.unref();
      reply.returnErrorMessage("OutOfMemory"); // <-- USE-AFTER-FREE
      return 1;
  };
  ```
- **Remediation**:
  Invoke `reply.returnErrorMessage(...)` *before* dropping references:
  ```zig
  const gtk_reply = std.heap.smp_allocator.create(GtkReply) catch {
      reply.returnErrorMessage("OutOfMemory");
      reply.unref();
      context.unref();
      return 1;
  };
  ```

---

#### [MEDIUM] MEM-02: Permanent Heap Leak on Error Path in `share:read`
- **Location**: `src/core/ipc.zig:383-395`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. A webview client calls `share:read` with a valid file handle.
  2. `var bytes: std.ArrayList(u8) = .empty;` is initialized.
  3. `share.read(args.handle, args.offset, len, &bytes)` reads up to 16 MiB from disk into heap-allocated `bytes`.
  4. `arena.alloc(u8, enc.calcSize(bytes.items.len))` fails with `error.OutOfMemory`.
  5. The function exits immediately. Because `bytes.deinit(std.heap.smp_allocator)` is located *after* the `try arena.alloc`, `bytes` is never freed, leaking up to 16 MiB of system memory per failed call.
- **Remediation**:
  Use `defer bytes.deinit(heap.gpa);` immediately following the declaration of `bytes`. Note that `heap.gpa` must be used instead of hardcoded `smp_allocator` to preserve Android compatibility (`c_allocator`).

---

#### [MEDIUM] MEM-03: `SoupMessageHeaders` Leaked on All Asset & Media Loads
- **Location**: `src/platform/linux/scheme.zig:52` and `src/modules/media_scheme/linux.zig:173, 212, 227`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. WebKitGTK requests an embedded asset or media chunk.
  2. The handler creates response headers: `const headers = soup.MessageHeaders.new(.response);`.
  3. The handler associates the headers: `response.setHttpHeaders(headers);`.
  4. Code comments assume `setHttpHeaders` sinks ownership. However, in libwebkitgtk (`webkit_uri_scheme_response_set_http_headers`), the C code calls `soup_message_headers_ref(headers)`.
  5. Because Oriel never calls `headers.unref()`, every web resource load permanently leaks a `SoupMessageHeaders` instance and its allocated string table.
- **Remediation**:
  Add `defer headers.unref();` immediately after creating `soup.MessageHeaders.new(.response)`.

---

#### [MEDIUM] MEM-04: Cross-Allocator Mismatch on Window Deallocation
- **Location**:
  - Allocation: `src/core/App.zig:600-610` (`heap.gpa`)
  - Deallocation: `src/platform/linux/window.zig:360`, `src/platform/windows/window.zig:1608`, `src/platform/macos/window.zig:518` (`std.heap.smp_allocator`)
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. An application window is created via `openWindow`, which allocates `win_inst`, `label`, `title`, and `url` using `heap.gpa`.
  2. When built with a non-default allocator (e.g. testing with `std.testing.allocator`, or on Android where `heap.gpa` is `std.heap.c_allocator`), destroying the window calls `std.heap.smp_allocator.free(...)` and `std.heap.smp_allocator.destroy(...)`.
  3. The memory block is returned to an allocator that never allocated it, triggering heap corruption or immediate panics.
- **Remediation**:
  Standardize all platform window deallocations to use `heap.gpa` rather than hardcoding `std.heap.smp_allocator`.

---

#### [LOW] MEM-05: Argument Vector Defer Leak in Linux Dev Server
- **Location**: `src/platform/linux/dev_server.zig:23-28`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. `startDevServer` allocates an argument array `argv` of length `N`.
  2. A loop duplicates each string using `gpa.dupeZ(u8, arg)`.
  3. If iteration `i > 0` fails with `OutOfMemory`, `return null` executes immediately.
  4. Because the `defer for (argv[0..command.len])` cleanup is placed *after* the loop, it does not execute, leaking all previously duplicated arguments `0..i-1`.
- **Remediation**:
  Initialize elements of `argv` to `null` and declare the `defer` before the loop.

---

### 2. Concurrency, Race Conditions & Thread Safety

#### [CRITICAL] CONC-01: Data Race & Use-After-Free in `FileHandles` Table
- **Location**: `src/core/file_handles.zig:98-185`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. `FileHandles` stores file descriptors in `entries: std.AutoHashMapUnmanaged(u32, Entry)`.
  2. No mutex or synchronization primitive protects `FileHandles`.
  3. Worker Thread 1 runs an async IPC command executing `handles.read(..., handle, ...)`.
  4. Worker Thread 2 concurrently executes `share:release` for the same handle, calling `entries.remove(handle)` and `std.posix.close(entry.fd)`.
  5. The hash map's internal bucket array undergoes a data race (read and write without synchronization).
  6. Thread 1 proceeds to call `std.posix.pread(e.fd, ...)`. In a multithreaded server, another thread may have opened a separate file or socket and received the recycled descriptor, causing Thread 1 to read arbitrary private data from the wrong file.
- **Remediation**:
  Add a `std.Thread.RwLock` to `FileHandles`. Acquire a read lock during `read` / `nativePath` operations, and a write lock during `addPath` / `release`.

---

#### [CRITICAL] CONC-02: `worker_pool` Teardown Use-After-Free & Orphaned Tasks
- **Location**: `src/core/App.zig:19-23, 864-872` and `src/core/ThreadPool.zig:57-69, 92-104`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. `App.run` cleanup executes:
     ```zig
     defer {
         pool.deinit();
         worker_pool = null;
     }
     ```
  2. `pool.deinit()` sets `shutdown = true`, joins threads, and calls `pool.allocator.destroy(pool)`.
  3. While `deinit()` is executing or immediately after `destroy(pool)`, a concurrent event or UI thread calls `App.spawn()` or `App.getWorkerPool()`.
  4. Because `worker_pool` has not yet been set to `null`, it returns the deallocated pointer and calls `pool.post(&job.task)`, corrupting the freed memory.
  5. Furthermore, `ThreadPool.post` does not check `pool.shutdown`. Any task posted during shutdown is queued into `pool.head` and never processed or freed.
- **Remediation**:
  Store `worker_pool` as `std.atomic.Value(?*ThreadPool)`. Atomically exchange it with `null` *before* calling `pool.deinit()`. In `ThreadPool.post`, check `shutdown` under the lock and reject new tasks.

---

#### [HIGH] CONC-03: Use-After-Free Race Condition in `App.ensureWindow`
- **Location**: `src/core/App.zig:478-489`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. Thread 1 calls `ensureWindow("main")`. It finds the window configuration in `registered_windows` under `windows_mutex`.
  2. The block completes, unlocking `windows_mutex`, and returns `opts: WindowOptions` by value. Slices such as `opts.label` and `opts.url` still point to memory inside `registered_windows`.
  3. Thread 2 concurrently calls `registerWindow("main", new_opts)`. Under the mutex, it calls `freeRegistered(r.*)`, freeing the string memory.
  4. Thread 1 calls `openWindow(opts)`, which invokes `gpa.dupeZ(u8, opts.label)` on the freed memory, reading invalid memory.
- **Remediation**:
  Either perform window opening while holding `windows_mutex`, or duplicate string slices into temporary buffers before releasing the mutex.

---

#### [HIGH] CONC-04: Thread-Local Storage Dangling Pointer Across Threads in Async IPC
- **Location**: `src/core/ipc.zig:246-260, 510-545`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. An async IPC command fails on a worker thread using `ipc.fail("error details")`.
  2. The error message is formatted into worker thread-local storage: `threadlocal var fail_buf: [2048:0]u8`.
  3. `errorText(err)` returns a slice pointing directly into this worker thread's `fail_buf`.
  4. In `Job.run()`, `on_done(context, arena, result, err_z)` is called with this pointer.
  5. In `linux/bridge.zig`, `onWorkerDone` saves `self.err_name = err_name;` and schedules an idle callback on the main GTK loop.
  6. The worker thread finishes `Job.run()` and returns to `ThreadPool`. It immediately executes another task that fails and overwrites `fail_buf`.
  7. When the main loop runs `idleReply`, it reads corrupted or overwritten error text.
- **Remediation**:
  Duplicate `err_z` into the job's `arena` on the worker thread before calling `on_done`:
  ```zig
  const err_z = if (res_z == null) (alloc.dupeZ(u8, errorText(err)) catch @errorName(err)) else null;
  ```

---

#### [MEDIUM] CONC-05: Windows `FileWindowStream` Offset Rollback Data Race
- **Location**: `src/modules/media_scheme/windows.zig:176-205`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. `FileWindowStream.Read` handles byte range streaming in WebView2.
  2. When a read is requested, it atomically increments `current_offset` via `cmpxchgWeak`.
  3. If a short read occurs (fewer bytes returned than requested), it rolls back the offset:
     ```zig
     const short_fall = to_read - bytes_read;
     _ = self.current_offset.fetchSub(short_fall, .seq_cst);
     ```
  4. If Thread A and Thread B perform concurrent reads, and Thread A experiences a short read while Thread B has already advanced `current_offset`, Thread A's `fetchSub` decrements Thread B's offset. Subsequent reads retrieve corrupted, out-of-order chunks.
- **Remediation**:
  Serialize reads using a mutex or track per-request stream offsets instead of atomic subtraction on a shared counter.

---

### 3. Webview Bridge, IPC & Isolation Security

#### [HIGH] SEC-02: Subframe Origin Spoofing on Linux WebKitGTK
- **Location**: `src/platform/linux/bridge.zig:625-640`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. A window loads `app://app/index.html`.
  2. The page embeds an `iframe` pointing to an external domain or untrusted content.
  3. The child frame calls `window.webkit.messageHandlers.oriel.postMessage(...)`.
  4. `onMessage` receives the call and checks permissions:
     ```zig
     const page_url = webkit.webkit_web_view_get_uri(view);
     ```
  5. `webkit_web_view_get_uri(view)` returns the URI of the **top-level document** (`app://app/index.html`), rather than the iframe's origin.
  6. The untrusted iframe inherits top-level permissions, allowing it to dispatch privileged IPC commands.
- **Remediation**:
  Inspect the message sender frame in WebKitGTK and reject messages whose sender frame is not the main frame.

---

#### [HIGH] SEC-03: Isolation Frame Origin Bypass on Safari / WebKit
- **Location**: `src/core/isolation.zig:280-360`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. In the isolation frame runtime JavaScript:
     ```javascript
     const ao = location.ancestorOrigins;
     if (ao && (ao.length !== 1 || !parents.includes(ao[0]))) return;
     ```
  2. `location.ancestorOrigins` is a Chromium-only proprietary API. On WebKit (macOS, iOS, Linux), `ancestorOrigins` is `undefined`.
  3. The check evaluates to `false` and is completely bypassed. Any site can embed the isolation endpoint.
  4. When an isolated command resolves, it executes:
     ```javascript
     parentWin.postMessage({ id: msg.id, res: result }, "*");
     ```
  5. The wildcard target `*` broadcasts sealed command responses to whichever origin embedded the frame.
- **Remediation**:
  Enforce frame restrictions via HTTP headers (`Content-Security-Policy: frame-ancestors 'self' app://app;`) and replace `postMessage(..., "*")` with the explicit parent origin.

---

#### [HIGH] SEC-04: Plaintext IPC Secret Token Exposure in Bridge Scripts
- **Location**: `src/core/ipc.zig:134-178`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. `ipc.tokenScript()` embeds HMAC secret tokens as literal strings in injected JavaScript.
  2. On Windows (`AddScriptToExecuteOnDocumentCreated`) and macOS (`WKUserScript`), this script is injected into all navigations and frames.
  3. Navigating to an external page or injecting a cross-origin frame allows the page to inspect the script source or extract the token from `globalThis.__orielNative` / bridge closures.
  4. With the `"local"` token, an attacker can forge authorized IPC messages.
- **Remediation**:
  Only inject bridge scripts into authorized, matching origins, and scope tokens per window/frame origin.

---

#### [MEDIUM] SEC-05: Privilege Escalation / Spoofing via `oriel:window:emitTo`
- **Location**: `src/core/window_commands.zig:100-115`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. Window commands like `close`, `show`, `setTitle`, and `setSize` validate permissions with:
     ```zig
     try security.validateWindowModification(sec, caller_win_label, args.label);
     ```
  2. `oriel:window:emitTo` completely omits `validateWindowModification`.
  3. An untrusted window or restricted capability origin granted basic `window_api` can emit arbitrary events to other windows (such as `main`), spoofing system events like `deep-link` or `permission-changed`.
- **Remediation**:
  Add `try security.validateWindowModification(sec, caller_win_label, args.label);` inside `emitTo`.

---

### 4. File System & Path Traversal

#### [CRITICAL] SEC-01: Arbitrary File Deletion in Apple Share Target
- **Location**: `src/modules/share/apple.zig:88-104`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. When handling shared items on macOS/iOS, `removeCopy(path)` cleans up copied items:
     ```zig
     pub fn removeCopy(path: []const u8) void {
         if (std.mem.indexOf(u8, path, "/Documents/Inbox/") == null) return;
         var buf: [std.fs.max_path_bytes]u8 = undefined;
         const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
         _ = std.c.unlink(z);
     }
     ```
  2. A crafted path containing traversal segments (e.g. `/path/to/Documents/Inbox/../../Library/Application Support/database.sqlite`) contains the substring `"/Documents/Inbox/"`.
  3. `unlink` executes on the traversed path, deleting sensitive files outside the inbox directory.
- **Remediation**:
  Canonicalize the path with `std.fs.realpath` and verify that `std.mem.startsWith(u8, resolved, inbox_dir)` holds without traversal.

---

#### [MEDIUM] SEC-06: Tarball Hard Link Bypass in macOS Updater
- **Location**: `src/modules/updater/macos.zig:185-230`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. During macOS `.app` bundle updates, `LinkGuard.entry` inspects archive entries to prevent extraction attacks.
  2. It only checks `file.kind == .sym_link`, completely ignoring `file.kind == .hard_link`.
  3. A crafted update tarball can specify hard links pointing outside the bundle, allowing extraction to modify or overwrite arbitrary files owned by the user.
- **Remediation**:
  Inspect `file.kind == .hard_link` in `LinkGuard` and reject hard links or validate that their targets remain within the bundle root.

---

### 5. Network & Auto-Updater Security

#### [HIGH] DOS-01: Unbounded Gzip Decompression (Zip-Bomb) in Updater
- **Location**: `src/updater_core.zig:393-402, 474`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. `updater_core.zig` verifies downloaded byte count against `update.size` (`downloaded_bytes > update.size`).
  2. In `downloadInternal`, it decompresses the payload to disk:
     ```zig
     while (true) {
         const n = try decompress.reader.readSliceShort(&out_buf);
         if (n == 0) break;
         try out_writer.interface.writeAll(out_buf[0..n]);
     }
     ```
     The decompression loop has no limit on the number of uncompressed bytes written to disk. A 10 MiB compressed payload that expands to 1 TB will write until the disk is full.
  3. In `unpack`, it decompresses in memory using `decompress.reader.allocRemaining(gpa, .unlimited)`, allowing memory exhaustion.
- **Remediation**:
  Enforce a maximum decompression threshold (e.g. 5x `update.size` or a hard limit like 500 MiB) across both disk streaming and memory extraction.

---

#### [MEDIUM] SEC-07: Unvalidated HTTP Redirects & SSRF in Model Downloader
- **Location**: `src/modules/model_download.zig:49-65`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. `model_download.fetch` follows up to 5 HTTP 301/302 redirects.
  2. When resolving `Location` headers, it does not check if the scheme is downgraded from `https` to `http`.
  3. It does not prevent redirection to private or loopback IP ranges (`127.0.0.1`, `169.254.169.254`), exposing internal endpoints to SSRF.
- **Remediation**:
  Ensure the scheme remains `https` upon redirect, and block resolutions to private/loopback IP addresses.

---

#### [MEDIUM] SEC-08: DNS Rebinding & CORS Port Scanning on Embedded Media Server
- **Location**: `src/modules/media_server.zig:33-70`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. The embedded HTTP streaming server does not validate the `Host` header.
  2. The `/ping` endpoint responds with `Access-Control-Allow-Origin: *`.
  3. An external website visited by the user in a regular browser can scan loopback ports to detect active Oriel instances.
  4. Via DNS rebinding, external sites can read files served by the media server.
- **Remediation**:
  Enforce that the `Host` header matches `127.0.0.1:{port}` or `localhost:{port}`, and restrict CORS origins to the application origin.

---

#### [LOW-MEDIUM] SEC-09: Updater Manifest Expiration & Replay Attacks
- **Location**: `src/updater_core.zig:220-225`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. The `expires` timestamp field in `Manifest` is optional (`?u64 = null`).
  2. If omitted, manifests are considered valid indefinitely.
  3. A network attacker can replay an older, legitimately signed manifest (e.g. v1.1.0 containing known vulnerabilities) to a victim running v1.0.0, even after v1.2.0 has been released.
  4. The check `now_ts > 0 and @as(u64, @intCast(now_ts)) > exp` skips expiration checks if system time is negative or zero.
- **Remediation**:
  Require a mandatory `expires` field on production manifests with a maximum validity window, and alert on non-positive system timestamps.

---

#### [LOW] BUG-01: Linux Command-Line Truncation on Updater Restart
- **Location**: `src/modules/updater/linux.zig:44-48`
- **Status**: **CONFIRMED**
- **Concrete Failure Scenario**:
  1. On restart after an update, `linux.zig` reads `/proc/self/cmdline`.
  2. It performs a single `readSliceShort` into a 2048-byte buffer.
  3. If command-line arguments exceed 2048 bytes (up to `MAX_CMDLINE_LEN` = 16384 bytes), arguments are truncated, causing corrupt argument parsing when the new executable starts.
- **Remediation**:
  Read in a loop until EOF or until `MAX_CMDLINE_LEN` is reached.

---

## Prioritized Remediation Plan

### Phase 1: Critical Fixes (Immediate)
1. **Fix Use-After-Unref in `src/platform/linux/bridge.zig`**:
   Ensure `reply.returnErrorMessage(...)` is invoked before `reply.unref()`.
2. **Add Mutex to `src/core/file_handles.zig`**:
   Protect hash map operations and descriptor accesses against concurrent mutation.
3. **Atomicize `worker_pool` in `src/core/App.zig`**:
   Set `worker_pool` to `null` before invoking `pool.deinit()`.
4. **Fix Directory Traversal in `src/modules/share/apple.zig`**:
   Canonicalize paths before invoking `unlink`.
5. **Duplicate Error Strings in `src/core/ipc.zig`**:
   Duplicate `err_z` into `arena` to prevent cross-thread dangling pointers.

### Phase 2: High & Medium Security Hardening
1. **Validate Subframe Origins in `src/platform/linux/bridge.zig`**:
   Reject IPC messages originating from non-main frames.
2. **Harden Isolation Frame in `src/core/isolation.zig`**:
   Use CSP `frame-ancestors` and specify parent origin in `postMessage`.
3. **Add Permission Validation to `emitTo` in `src/core/window_commands.zig`**:
   Invoke `validateWindowModification`.
4. **Enforce Decompression Limits in `src/updater_core.zig`**:
   Bound uncompressed size during gzip expansion.
5. **Fix Memory Leaks**:
   Add `defer headers.unref()` for `SoupMessageHeaders` in WebKitGTK, and `defer bytes.deinit(...)` in `share:read`.
6. **Standardize Allocator Usage**:
   Use `heap.gpa` consistently across window destruction routines.
