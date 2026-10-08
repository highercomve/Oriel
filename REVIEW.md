# Validated security and memory-safety review

Validated on 2026-10-08 against `56b360e` (Oriel 0.9.4 plus website documentation).
The original report's blanket “CONFIRMED” labels and severity ratings were not
accepted as evidence. Each finding was checked against its callers, ownership
contracts, the installed Zig 0.16.0 standard library, and platform APIs.

All confirmed implementation defects below are addressed for **0.9.5**.
“Not confirmed” means the reported mechanism is contradicted by the current
code or lacks a working exploit; it does not claim the subsystem is free of
other bugs. This is a targeted validation of the supplied findings, not a new
full-codebase security audit.

## Finding results

| ID | Validation | Result / evidence |
|---|---|---|
| MEM-01 | Not confirmed as a use-after-free | Linux adds a reply reference, then releases only that added reference on setup failure. WebKit retains the callback's borrowed reply until the handler returns. The reply is therefore still alive; this is not the claimed sole-reference scenario. |
| CONC-01 | Confirmed; fixed | `FileHandles` now serializes map access and holds its lock through descriptor reads, checks and path lookup. Descriptor duplication is performed under the same lock; Apple/Windows sharing no longer duplicate a descriptor returned by an unlocked `info()` call. |
| CONC-02 | Confirmed; fixed | App pool publication and borrowing are synchronized. Shutdown withdraws the pointer, waits for outstanding borrows, then drains/destroys the pool. Posting after shutdown is rejected and callers release rejected jobs. Merely atomically exchanging the pointer would leave already-loaded pointers unprotected. Pool initialization allocation failure is also cleaned up. |
| SEC-01 | Unsafe deletion guard confirmed; fixed | iOS Inbox cleanup now canonicalizes the app container's actual Inbox and file, requires a direct child, and unlinks through a directory descriptor. macOS never performs Inbox cleanup. The path comes from OS sharing / trusted Zig code, not a page-supplied arbitrary deletion command; the original remote exploit severity was overstated. |
| SEC-02 | Origin metadata limitation confirmed; exploit not established | WebKit's reply signal does not expose a sender frame. Linux's bridge is injected only into top frames on permitted origins, and native dispatch verifies the scoped token before using the top-level URL. An untrusted child receives no bridge token; directly posting without it is refused. Existing smoke checks exercise that refusal. No untrusted-frame token extraction was demonstrated. |
| SEC-03 | Missing fallback validation confirmed; fixed | Isolation messages now require the actual `MessageEvent.origin` to match a local parent and require a direct top-level parent. Responses target the validated origin; readiness targets only configured local origins. CSP `frame-ancestors` already existed. The fix does not depend on the report's inaccurate blanket claim that all WebKit engines lack `ancestorOrigins`. |
| SEC-04 | Token-extraction claim not confirmed | Injected values are derived scope tokens, not the HMAC master key. Tokens remain in a document-start closure; `__orielNative` is not an exported token container. Native authorization checks both token scope and page origin/capabilities. Apple scripts are main-frame-only and Apple handlers reject subframes. Linux uses top-frame injection and an origin allowlist. Windows/Android shared bridge now exits immediately in subframes for consistency. Reading a native user script's source from an arbitrary page was asserted, not demonstrated. |
| CONC-03 | Confirmed; fixed | `ensureWindow` snapshots the registered label, title and URL while holding the registration lock; the snapshot survives concurrent replacement and is freed after opening. Window creation itself remains a main-thread API. |
| CONC-04 | Confirmed; fixed | Async error text is copied into the job arena before handing it to UI callbacks, including custom `ipc.fail` text. A regression test retains two errors after the same worker is reused and destroyed. |
| DOS-01 | Unbounded expansion confirmed; fixed | Expanded gzip output is limited to 512 MiB for disk streaming and heap unpacking. macOS bundle verification and extraction are bounded too. The compressed payload must already pass signed-manifest/hash checks; an unsigned network payload cannot directly trigger the described expansion. |
| SEC-05 | Confirmed; fixed | `oriel:window:emitTo` now applies `validateWindowModification`, matching other window mutation commands. Cross-window emission requires `allow_modify_other_windows`; self-targeted events retain existing behavior. |
| SEC-06 | Not confirmed | Zig 0.16.0 `std.tar.FileKind` has only directory, symlink and file. The iterator skips unsupported entries, including hard links; extraction never creates them. Adding `.hard_link` to `LinkGuard` would not compile. Existing symlink checks remain in place. |
| SEC-07 | HTTPS downgrade confirmed; fixed; SSRF claim not established | The Zig downloader requires HTTPS before every request, including resolved redirects, and refuses URL credentials. Initial model URLs come from compiled Hugging Face catalogue entries, not page-supplied URLs; downloaded response bytes are stored as model files, not returned to a remote caller. iOS uses NSURLSession/system TLS and App Transport Security for redirects. This is not a general SSRF-safe downloader: arbitrary private-address/DNS destinations are not comprehensively filtered, so trusted catalogue/CDN endpoints remain part of its trust model. |
| MEM-02 | Confirmed; fixed | The share-read buffer is deferred immediately, covering read errors and base64 allocation errors. The received-file table and its output buffer cleanup use the same internal allocator. |
| MEM-03 | Not confirmed; proposed fix would be unsafe | `webkit_uri_scheme_response_set_http_headers` takes full ownership. The installed GIR and WebKit documentation specify transfer-full. Adding `headers.unref()` after transferring ownership would risk double-unref/use-after-free. |
| MEM-04 | Not confirmed in current builds; ownership made explicit | `heap.gpa` is `smp_allocator` on Linux/Windows/macOS; Android uses its own backend and allocator. There is no configurable allocator override in the reviewed allocation path. Desktop window destruction now names `heap.gpa` explicitly to preserve the ownership contract if that implementation changes. |
| CONC-05 | Confirmed; fixed | Windows stream Read and Seek are serialized. Reads advance by actual bytes read after success, so a failed/short read cannot roll back another request's offset. |
| SEC-08 | Confirmed; fixed | All local media endpoints validate Host against the configured loopback address/port before serving. `/ping` now uses the configured application CORS origin. File CORS was already scoped; only ping had the wildcard. Real TCP tests reject rebinding Host values on GET, HEAD and OPTIONS. |
| SEC-09 | Optional freshness policy, not a signature/downgrade bypass; clock edge fixed | Expiration remains optional for compatibility with published manifests and offline release lifetimes. Signatures and newer-than-current version checks still apply; intentional `force` is the explicit downgrade path. A valid older-but-newer-than-installed signed manifest can remain usable without expiry, so strict freshness requires a publisher policy. When an expiry is present, a non-positive clock now fails closed. |
| MEM-05 | Confirmed; fixed | Dev-server argv elements are initialized to null and cleanup is registered before duplication, so partial allocation failure releases prior strings. |
| BUG-01 | Not confirmed | The 2048-byte array is the reader's internal buffer, not the destination bound. `readSliceShort` loops to fill the 16385-byte destination or EOF, and the existing length check rejects oversized command lines. |

## API and behavior changes

- `App.getWorkerPool()` returns a borrow that must be paired with
  `App.releaseWorkerPool()` when non-null. All internal bridge callers are
  updated. `App.spawn()` manages this automatically.
- `ThreadPool.post()` returns whether it accepted the task. On rejection the
  caller retains task ownership and must clean it up.
- Cross-window `emitTo` requires the same modification permission as other
  cross-window operations.
- Gzip-based update payloads larger than 512 MiB after expansion are refused.
  This includes macOS bundle archives. Raw update formats retain their signed
  size bounds. Publishers of larger compressed bundles must account for this
  limit.
- Model catalogue URLs and Zig-followed redirects must use HTTPS.
- Media-server clients must use `127.0.0.1:<port>` or `localhost:<port>` as Host.

## Validation

Regression tests cover table contention and descriptor duplication, pool
withdrawal/draining/rejection, retained async error text, cross-window event
permissions, Inbox path restrictions, real-TCP Host rejection, HTTPS URL
validation, and bounded gzip writes. `tools/test_isolation_runtime.mjs`
executes the embedded runtime without `ancestorOrigins`, checks untrusted
origins/sources, and verifies explicit reply origins. The release workflow
runs this test along with the existing unit and WebView smoke checks.

Linux unit tests and Windows cross-target type checks pass locally. The real
Linux smoke app is checked in a private Xvfb/D-Bus session. macOS framework
verification runs on the macOS release runner because this Linux host lacks
Apple frameworks. No iOS device run or Windows IStream runtime concurrency
stress test is claimed by this validation.

## Ownership and library references

- [WebKit response header ownership](https://webkitgtk.org/reference/webkit2gtk/unstable/method.URISchemeResponse.set_http_headers.html): full ownership transfer; also checked in `/usr/share/gir-1.0/WebKit-6.0.gir`.
- [WebKit reply signal](https://webkitgtk.org/reference/webkitgtk/stable/signal.UserContentManager.script-message-with-reply-received.html): borrowed callback reply and async retention contract.
- Installed Zig 0.16.0: `lib/std/Io/Reader.zig` (`readSliceShort`),
  `lib/std/tar.zig` (`FileKind`, iterator and extraction), and
  `lib/std/Io/Threaded.zig` (blocking mutex implementation).
