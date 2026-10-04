# Drag and drop for Oriel: design

Status: proposal (2026-10-04). Scope: drops into pages (files, text, URIs) in the native renderer on every
backend, in-page HTML5 drag and drop, drags out of the page, and what WebView mode needs.
Targets: Google's large-screen/desktop-Android checklist (drag and drop between windows and apps on
ChromeOS) and parity with desktop browsers.

## 0. What exists today (findings)

- `main.js` `__oriel.event(id, type, data)` dispatches "pointer", "hover", "contextmenu", etc. Its return value
  goes through `dispatch_result` (`src/native_ui/qjs_shim.c:939`, `JS_ToBool`) and `Engine.finishDispatch`
  (`engine.zig:582`), so a backend can only get a **bool** back. A drop needs an operation (copy/move/link).
- Backends hit-test before calling JS (`tree.hit(x, y)` in `android.zig sendPointer`, `gtk.zig sendPointer`), and
  `main.js pointerEvent` turns that into DOM events and forwards them to window listeners (`fireWindow`).
- The runtime has **no Blob, File, FileReader, FileList, DataTransfer or DragEvent**, and no TextDecoder (QuickJS-ng;
  `icons.js:70`). `url.js:165` refuses blob: URLs. `HANDLER_EVENTS` (main.js ~1190) has no drag names.
  `FinalizationRegistry` is available (`canvas.js:590` already uses it).
- No file module: `src/modules/dialog/*` returns **paths to Zig code**, not to the page. On Android it copies the
  pick into `<cacheDir>/picked/` or hands out `/proc/self/fd/<n>`. That shows the pattern: on Android, a held
  descriptor is the capability.
- `security.navigation` (`src/core/security.zig:296`) blocks `file:` (test at line 713). Linux decide-policy
  (`platform/linux/window.zig:407`), WebView2 NavigationStarting/NewWindowRequested (`platform/windows/window.zig:531,653`),
  WKWebView decidePolicy (`platform/macos/window.zig:591`, `platform/ios/window.zig:604`) and Android
  `shouldOverrideUrlLoading` (`OrielWindow.kt:234`) all go through it.
- Windows: the native renderer only calls `CoInitializeEx(STA)` (`win32.zig:3906`). `RegisterDragDrop` needs `OleInitialize`.
- Android: `OrielFileProvider` already serves `<cacheDir>/oriel-shared/` read-only via per-URI grants (clipboard images).
  Drags out can reuse it.

## 1. Engine event family (backend to JS)

One engine event type, `"drag"`, on the hit-tested node id (0 = none, which becomes `document.body`). Coordinates are
the same as "pointer": CSS px in the surface's coordinates. Operations are a bitmask, **copy 1, move 2, link 4**, which
is the same as Win32 `DROPEFFECT_*`. `mods` uses the pointer flags (shift 1, ctrl 2, alt 4, meta 8).

| phase | data | JS returns |
|---|---|---|
| enter | `["enter", x, y, allowed, suggested, mods, session, items]`, items `[[kind, type], ...]` | effect mask |
| over  | `["over", x, y, allowed, suggested, mods, session]` | effect mask |
| leave | `["leave", session]` | 0 |
| drop  | `["drop", x, y, allowed, suggested, mods, session, items]`, items with payload (below) | effect performed |

- `kind` is `"string"` or `"file"`. Drop payload items: `["string", "text/plain", value]` or
  `["file", mime, name, size, lastModifiedMs, handle]`. `handle` is a u32 key into the engine's drop table (section 3).
- `session` is a per-OS-drag counter, so JS can tell a new drag from a late event. `suggested` is the OS's preferred
  operation (it reflects the modifier keys), which becomes the initial `dropEffect`.
- **Never expose a file's path.** If the OS offers both a file list and `text/uri-list`/`text/plain` with `file://`
  URIs for the same drag, backends send only the file items. Chrome does the same (types are `["Files"]` only).
- Caps, enforced by the backend: at most 4096 items, and at most 16 MiB per string (larger strings are dropped and logged).

**Return path.** Add `oqjs_event_code` to `qjs_shim.c`. It is the same as `oqjs_event` but uses `JS_ToInt32`
instead of `JS_ToBool`. Add `Engine.dragEvent(e, id, json) u8` in `engine.zig` (same `in_call`/`finishDispatch`
bookkeeping, returning the masked int). The existing bool callers stay as they are.

**Asynchronous data.** On GTK, UIKit and Android the dropped data arrives after the OS drop callback, so the OS
gets its answer from the **last over effect**, which the backend caches in its Surface. JS "drop" is then
dispatched when the items are ready. On Win32 and AppKit the data is synchronous, so the drop's own return value is
used. For copy this makes no difference. For move it means the page cannot downgrade to "none" at drop time on the
async platforms. Document this.

**Rate.** "over" is sent on every OS motion, but the backends that defer pointer moves to the display frame
(android.zig `s.move`/`postFrame`) do the same for drags. Win32 DragOver, AppKit draggingUpdated and GTK drag-motion
need a synchronous answer, so they call JS directly. These calls are cheap because `settle` defers the render
via `request_frame`.

## 2. JS side

New modules: `src/native_ui/js/src/blob.js` (Blob, File, FileReader, FileList) and `src/native_ui/js/src/dnd.js`
(DataTransfer, DataTransferItem(List), DragEvent, the drag state machine). Both are imported by `main.js`. Add a
`case "drag":` to `__oriel.event` that calls `dnd.dragEvent(el, data)`. `__oriel.fileData` comes in with blob.js.

**DragEvent** extends main.js's `MouseEvent` (clientX/Y, buttons, mods) and adds `dataTransfer`. Install
`g.DragEvent`, `g.DataTransfer`, `g.Blob`, `g.File`, `g.FileList`, `g.FileReader`. Add `drag dragend dragenter
dragleave dragover dragstart drop` to `HANDLER_EVENTS`. React's root listeners and `ondrop=` need these.

**State machine (dnd.js)**, following the HTML spec's drag-and-drop processing model:
- enter/over: `target = el || document.body` (not connected, treated as changed). When the target changes, fire
  `dragenter` on the new target first (bubbles, cancelable), then `dragleave` on the old one (bubbles), then
  `dragover` on the target (bubbles, cancelable). Every event also goes to window listeners, the same way
  `pointerEvent`'s `fire` does it. Factor that helper out.
- The initial `dropEffect` for dragover comes from effectAllowed and `suggested` (spec table: copyMove gives
  suggested, link gives link, and so on).
- If dragover was canceled, effect = `dropEffect` if `effectAllowed` permits it, else none. If it was not canceled,
  the default action applies: if the target is an editable (`input`, `textarea`, `[contenteditable]`) and the drag
  has `text/plain`, the effect is copy; otherwise none.
- leave: fire `dragleave` on the current target and clear the state.
- drop: if the last effect is none, fire `dragleave` and return 0 (the spec doesn't fire drop then). Otherwise fire
  `drop` with a read-only DataTransfer. If it is canceled, return the dropEffect mask. If not, run the default:
  insert the text into the editable target the same way a native edit does (set the value, then `input`), and
  return copy. Otherwise return 0.

**DataTransfer** has three modes, as in the spec:
- **protected** (enter/over/leave): `types`, plus `items` with kind and type. `getData()` returns "", `files` is
  empty, and `getAsFile()` returns null.
- **read-only** (drop): everything is readable.
- **read/write** (dragstart only, phase 2): `setData`, `clearData`, `effectAllowed`, `setDragImage`.

Members: `dropEffect`, `effectAllowed` (validated strings), and `types`, a frozen array that includes `"Files"` when
any item is a file (react-dropzone's `isEvtWithFiles` checks for that). `getData(fmt)` lowercases the format, maps
`text` to `text/plain` and `url` to the first non-comment line of `text/uri-list`. `files` is a FileList (`length`,
`item(i)`, indexable). `items` is a DataTransferItemList (`length`, `[i]`, `add`, `remove`, `clear`). Each item has
`kind`, `type`, `getAsString(cb)` (the callback runs as a microtask) and `getAsFile()`. Omit `webkitGetAsEntry` for
now: file-selector, which react-dropzone uses, checks `typeof ... === "function"` and falls back to `getAsFile()`.
`new DataTransfer()` is constructible, because some code builds a FileList with it.

**Blob/File (blob.js).** A Blob holds segments: `{bytes: Uint8Array}` or `{handle, offset, length}`.
- `new Blob(parts, {type})` takes strings (UTF-8 encoded in JS), ArrayBuffer and views, and Blobs.
- Methods: `size`, `type`, `slice(start, end, type)` (no I/O; handle segments narrow), `arrayBuffer()`, `bytes()`,
  `text()` (a small JS UTF-8 decoder with replacement chars). `stream()` comes later.
- `File extends Blob` adds `name`, `lastModified` and `webkitRelativePath = ""`. It must stay extensible, because
  file-selector defines `path` on it.
- `FileReader` is an EventTarget with `readAsArrayBuffer`, `readAsText`, `readAsDataURL` (base64 with `btoa` over
  32 KiB chunks), `abort`, `readyState`, `result`, `error`, and `load`/`loadend`/`error`/`progress` events plus the
  `on*` handler properties.
- Handle reads: `host.fileRead(reqId, handle, offset, length)`, answered by
  `__oriel.fileData(reqId, ArrayBuffer | null, errorName)`. Reads are **always async**, as in the web: there is no
  sync API outside workers. A failure rejects with `DOMException("NotReadableError")`.
- Lifetime: one `FileRef {handle}` object is shared by a File and its slices. It is registered with a
  `FinalizationRegistry` whose callback calls `host.fileRelease(handle)`.

**Minimum for common libraries.**
- Plain HTML5 handlers: `ondragover = e => e.preventDefault()`, `drop` with `e.dataTransfer.files`/`getData`, and `FileReader`.
- react-dropzone 14 / file-selector: dragenter/over/leave/drop on the root and `preventDropOnDocument` listeners on
  `document`; `types` containing "Files"; `items[i].kind/type/getAsFile()`; `File.name/size/type`; extensible File;
  `dropEffect` assignable inside try/catch.
- Not covered: clicking the zone opens `<input type=file>`, which the native renderer doesn't implement (open question).

## 3. File access security

- **The capability is an open, read-only descriptor, not a path.** At drop time the backend opens each file:
  `open(O_RDONLY|O_CLOEXEC)`, or `CreateFileW(GENERIC_READ, FILE_SHARE_READ|WRITE|DELETE)`, or the fd of an Android
  `ParcelFileDescriptor`. It then `fstat`s the descriptor and keeps only regular files; directories are skipped in
  phase 1. The page gets a u32 handle, the basename, the MIME type (from the OS, or guessed from the extension), the
  size and mtime. No path ever reaches JS.
- **Table:** new `src/native_ui/drop.zig`, `DropFiles` with `std.AutoHashMapUnmanaged(u32, Entry{fd, size, mtime_ns})`.
  It is an `Engine` field (`e.drops`), so it is per window and per document. API: `addFd(fd) !u32`,
  `addPath(path) !?u32` (desktop), `read(handle, offset, len, out)`, `release(handle)`, `deinit()`.
  `Engine.destroy` calls `deinit`, which closes everything. Handle numbers can be sequential, because the table only
  holds what the user dropped into this engine, and `host.fileRead` cannot reach anything else.
- **Read-only, snapshot semantics:** on each read, `fstat` again. If size or mtime changed, return
  `NotReadableError`, as browsers do. Cap each read at 64 MiB. Larger `arrayBuffer()` calls read in chunks and
  assemble, up to a configurable ceiling, so a 4 GB file can't exhaust the QuickJS heap (open question).
- **Granted only by user action:** handles come only from OS drop callbacks (and later from `<input type=file>`).
  There is no host call that opens a path.
- **Isolation/IPC:** `host.fileRead` is not an IPC command, so the isolation hook does not see it. That is fine: the
  hook governs commands. The native renderer only loads app assets, so no remote origin can reach handles.
  `oriel.window.emitTo` JSON-serializes, so a File cannot cross windows.
- **Lifetime:** a handle lives until its last File is collected (FinalizationRegistry), the window closes, or the
  engine is destroyed. A held fd keeps working after the OS revokes the drag's grant: Android
  `DragAndDropPermissions.release()`, the macOS sandbox extension, and a deleted iOS temporary file (the fd keeps the
  inode alive).
- Android cache copies (non-seekable providers, see section 5) go in `<cacheDir>/oriel-dropped/<session>/`. They are
  unlinked right after opening, so the fd is the only reference and nothing is left behind.

## 4. Drags out of the page (later phases)

- **Phase 2, in-page HTML5 DnD, JS only, every backend.** On a pointer down on `[draggable=true]` (or a link or
  image), followed by a move of more than 4 px with the button held: fire `dragstart` with a read/write DataTransfer.
  If it is not canceled, start a JS-side session. Pointer moves then become `drag` on the source plus
  enter/over/leave on the element the backend hit-tested (pointer events already carry `el`). The up becomes `drop`
  and then `dragend`. Suppress pointer/mouse events and the click during the session. There is no drag image
  (`setDragImage` is a no-op). This covers SortableJS and react-dnd's HTML5Backend.
- **Phase 3, OS drag sessions.** The phase 2 session is replaced by an OS drag when the payload should leave the
  window: always on Android/ChromeOS, otherwise when `effectAllowed` and data permit. JS calls
  `host.startDrag(json)`, where json is `{types: {mime: string}, files: [handle], allowed}`, through a new optional
  `Backend.start_drag`. The backend:
  - GTK: `GtkDragSource` with a `GdkContentProvider` union of `gdk_content_provider_new_for_bytes` per MIME, plus a
    `GdkFileList` for files.
  - Win32: an `IDataObject` and `IDropSource`, then `DoDragDrop`. It runs a modal loop that still pumps WM_TIMER and
    the frame messages.
  - AppKit: `beginDraggingSessionWithItems:event:source:` with `NSPasteboardItem`s.
  - UIKit: `UIDragInteraction`, whose `itemsForBeginningSession` asks JS synchronously for the draggable at the
    point. iOS cannot start a drag programmatically.
  - Android: `View.startDragAndDrop(ClipData, DragShadowBuilder, null, DRAG_FLAG_GLOBAL | DRAG_FLAG_GLOBAL_URI_READ)`,
    with file payloads copied into `OrielFileProvider` URIs.

  The OS result becomes `dragend` with the final `dropEffect`. Drops back onto our own window come through the normal
  drop target, recognized by `session` and given the page's original data (custom MIME types included).

## 5. Per-platform backend work

**Android native renderer (phase 1).**
- `OrielNative.kt`: in `NuiView` (line 810), `override fun onDragEvent(e: DragEvent): Boolean`. Coordinates go from
  px to dp, as in the pointer code.
- `ACTION_DRAG_STARTED`: return true, so we keep receiving the drag and the page decides.
- `ENTERED` has no coordinates, so set a flag. The first `LOCATION` sends "enter" (items built from
  `e.clipDescription` MIME types: `text/plain`, `text/html` and `text/uri-list` are strings, anything else is a file
  of that type). Later locations send "over", coalesced with the Choreographer like `nPointer` moves.
- `EXITED` sends "leave". `ENDED` without a drop also sends "leave".
- `ACTION_DROP`:
  - Flush the pending over, return the cached effect != 0, and record the session.
  - If the ClipData has URIs, call `requestDragAndDropPermissions(e)` on the hosting Activity (unwrap
    `ContextWrapper`).
  - On a background executor, for each `ClipData.Item`: text comes from `item.text`/`htmlText`. For a `content://`
    URI, query `OpenableColumns.DISPLAY_NAME/SIZE` and `getType`, then call `openFileDescriptor(uri, "r")`. If
    `statSize < 0` or `Os.lseek` fails, copy the data into `oriel-dropped/`, open the copy and unlink it.
    `detachFd()` either way.
  - `perms.release()`, then post to the UI thread: `NuiNative.drop(window, session, x, y, itemsJson, fds: IntArray)`.
- `android.zig`: add `nDrag(win, phase, x, y, json) jint` and `nDrop(...)`, exported next to `nPointer`
  (`Java_dev_oriel_NuiNative_*`). `nDrop` calls `e.drops.addFd` for each fd, rewrites the items with handles and
  calls `e.dragEvent`. If the surface is gone (`byId` returns null), close the fds.
- Native `EditText` children accept *every* drag in `TextView.onDragEvent` and would insert a content URI as text.
  Give each field an `OnDragListener`: for a non-text `ClipDescription` it forwards the event to the NuiView handler
  (translating the offset) and returns true. Text drags keep the field's own insertion.

**GTK4 (phase 1).**
- In `gtk.zig` Surface setup (~line 393), create a `gtk_drop_target_async_new(formats, COPY|MOVE|LINK)`. `formats`
  is `GDK_TYPE_FILE_LIST` plus `text/plain;charset=utf-8`, `text/plain`, `text/uri-list` and `text/html`.
- Attach it to the **overlay**, not the area, so drags over native field overlays bubble up. GtkText's own string
  drop target still takes text over fields. Add it to `s.controllers`.
- Signals:
  - `accept`: return true.
  - `drag-enter` and `drag-motion`: hit-test, call `dragEvent`, map the mask to a single `GdkDragAction`.
  - `drag-leave`: send "leave".
  - `drop`: `gdk_drop_read_value_async(GDK_TYPE_FILE_LIST)`, which gives `GFile`s. For each, `g_file_get_path`
    (Flatpak portal paths work), `drops.addPath`, and `g_content_type_guess` for the MIME type. Text is read with
    `gdk_drop_read_async` into a `GMemoryOutputStream`. Then dispatch JS "drop" and call `gdk_drop_finish(drop, action)`.
- Guard async callbacks with the surface token (`surfaces.get(token)`, as `onPressed` does).
- Items: on enter, `gdk_content_formats_contain_gtype(GDK_TYPE_FILE_LIST)` adds `["file", ""]`, and the MIME types
  add string items. Leave out `text/uri-list` when a file list is present. `GFile`s without a path (gvfs) are
  skipped in phase 1.

**Win32 (phase 2).**
- `win32.zig`: call `OleInitialize(null)` once on the UI thread (it is compatible with the existing STA). Then
  `RegisterDragDrop(hwnd, &s.drop_target)` per surface and `RevokeDragDrop` on destroy. Child HWNDs (edit fields)
  are covered, because OLE walks up to the registered parent.
- Implement `IDropTarget` as a Zig vtable, following the handler pattern in `platform/windows/window.zig`:
  - `DragEnter`/`DragOver`: the `POINTL` point goes through `ScreenToClient` and is divided by the DPI scale.
    `grfKeyState` gives mods, `*pdwEffect` gives allowed; set `*pdwEffect` to `jsMask & allowed`.
  - Types: `CF_HDROP` (count with `DragQueryFileW(h, 0xFFFFFFFF)`, MIME types guessed from the extension),
    `CF_UNICODETEXT`, `UniformResourceLocatorW`, `HTML Format`.
  - `Drop`: `GetData(CF_HDROP)`, `DragQueryFileW`, then `drops.addPath`. Text comes from `GlobalLock`, converted
    UTF-16 to UTF-8, followed by `ReleaseStgMedium`. This is synchronous, so the drop's JS result is returned.
- Add `IDropTargetHelper` (`CLSID_DragDropHelper`) so Explorer's drag image keeps rendering over the window.
- Note: UIPI blocks drops from non-elevated Explorer into an elevated app.
- Virtual files (`CFSTR_FILEDESCRIPTORW` + `CFSTR_FILECONTENTS`, from Outlook) come later.

**AppKit (phase 2).**
- `appkit.zig classes()`: add `draggingEntered:`, `draggingUpdated:`, `draggingExited:`, `prepareForDragOperation:`
  and `performDragOperation:` to `OrielNuiView`.
- After creating the view, call `registerForDraggedTypes:` with `NSPasteboardTypeFileURL`, `NSPasteboardTypeString`,
  `NSPasteboardTypeURL` and `NSPasteboardTypeHTML`.
- The point is `convertPoint:[info draggingLocation] fromView:nil` (the view is flipped). Allowed comes from
  `draggingSourceOperationMask` (Copy 1, Link 2, Move 16, remapped to our bits). Mods come from
  `NSEvent.modifierFlags`.
- `performDragOperation:` reads `readObjectsForClasses:@[NSURL] options:@{NSPasteboardURLReadingFileURLsOnlyKey: YES}`,
  opens each file while the sandbox extension is live, and returns the JS result.
- `NSFilePromiseReceiver` (Photos, Mail) comes later.
- **Done (2026-10-04, appkit.zig).** drop.zig opens and `fstat`s through libc on Darwin (`std.c.fstat`; its unit
  tests run on macOS). The source's mask maps Copy to copy, Link to link, and Generic and Move to move; the
  suggested operation is the first the source allows (it narrows its mask with the modifiers). Tested with real
  drags from another app: two files and a folder give `types ["Files"]`, the two files' names, sizes, MIME types
  (UTType's, by extension: `text/plain`, `application/json`) and `f.text()`, the folder skipped; text gives
  `["text/plain"]` and its `getData`. Both match WKWebView's, except that WKWebView also lists the folder as a File.
  A drop where the page doesn't take the drag is refused (the source sees no operation).

**UIKit (phase 2, iPad).**
- Add a `UIDropInteraction` to the NuiView with a delegate class defined via the objc helpers:
  - `canHandleSession:`: YES.
  - `sessionDidUpdate:`: `UIDropProposal` with Copy, Move or Cancel. Move only if `session.allowsMoveOperation`.
  - `sessionDidExit:`: send "leave".
  - `performDrop:`: for text, `loadObjectOfClass:NSString`. Otherwise `loadFileRepresentationForTypeIdentifier:`,
    and **open the fd inside the completion handler** (the temp file is deleted when it returns). The name comes
    from `suggestedName`. A dispatch group then hops to the main queue and sends JS "drop".
- The point is `[session locationInView:view]`. iPhone only gets in-app drops.

**WebView mode.** Every WebView handles drops itself, and Oriel's navigation policy already contains the fallout:

| Platform | Native behavior | Oriel work |
|---|---|---|
| WebKitGTK | HTML5 drop with `DataTransfer.files`. An unhandled file drop loads `file://`, which decide-policy blocks (`security.navigation`, logged as a warning). | Verify on webkitgtk-6.0 (GTK4). Check whether an unhandled dropped **https link** counts as a user gesture and so opens the system browser (`.open_external`). |
| WebView2 | `AllowExternalDrop` (ICoreWebView2Controller4) defaults to TRUE, so files are delivered. An unhandled drop navigates to `file://`, which NavigationStarting/NewWindowRequested block. | Optional `put_AllowExternalDrop(FALSE)` behind a config flag. Same link check as GTK. |
| WKWebView macOS / iOS (iPad) | Files delivered. `file:` navigation is blocked in decidePolicy. | Verify on iPad. |
| Android WebView | **Verified on ChromeOS (Android 13, 2026-10-04):** a file dragged from the Files app reaches HTML5 handlers as a real `File` (name, size, MIME); a link dropped where the page has no handlers does nothing (no navigation, no browser). | None. |

Do not inject a global "prevent unhandled drop" guard into WebView pages. A window-level listener registered first
would set `dropEffect = "none"` before the page's own window listeners run, which breaks pages that only call
`preventDefault`. The policy already blocks `file:`. Document the Electron-style
`document.addEventListener("dragover"/"drop", e => e.preventDefault())` for apps that want it.

## 6. Phased plan

**Phase 1: file and text drops into native-renderer pages on Android and GTK4.**
1. `qjs_shim.c`: `oqjs_event_code`, `h_file_read`, `h_file_release`, and `oqjs_file_data`, which calls
   `__oriel.fileData` with a `JS_NewArrayBufferCopy`. `engine.zig`: `dragEvent`, `fileData`, the `drops` field and
   cleanup in `destroy`.
2. `src/native_ui/drop.zig` (the table and snapshot checks) with Zig unit tests: add/read/release, a bad handle,
   an mtime change giving an error, and a directory rejected.
3. `blob.js` and `dnd.js`, the `main.js` wiring (`case "drag"`, HANDLER_EVENTS, globals, `fileData`), then rebuild
   `runtime*.js`.
4. Android: `NuiView.onDragEvent`, the EditText forwarding, and `nDrag`/`nDrop` in `android.zig`.
5. GTK: `GtkDropTargetAsync` on the overlay in `gtk.zig`.
6. Docs: a "Drag and drop" section in `docs/native-renderer.md` next to "Pointer and key events".
7. A manual WebView verification pass (no code): each WebView, a fixture page, file drop, link drop, unhandled drop.

Node tests in `src/native_ui/js/test`, in the `mouse-buttons.test.mjs` style (vm context, fake `host`, then
`ctx.__oriel.event(id, "drag", [...])`), added to `package.json` "test":
- `drag-events.test.mjs`:
  - enter/over/leave order across two boxes (dragenter on the new box before dragleave on the old).
  - Return codes: 0 when nothing prevents, 1 with `preventDefault` + `dropEffect="copy"`, 0 when the dropEffect is
    outside effectAllowed.
  - Protected mode (`getData` returns "", `files.length` is 0, `types` includes "Files").
  - Drop with `getData` and `files[0].name/type/size`.
  - A drop that isn't prevented returns 0 and doesn't fire `drop` after an over whose effect was none.
  - Window and document listeners fire, as do `ondrop=` and inline `ondragover="event.preventDefault()"`.
  - Text dropped on a `<textarea>` gets the default insertion and fires `input`.
- `blob.test.mjs`: Blob from strings, multi-byte UTF-8 and buffers; `slice`/`text`/`arrayBuffer`; `File` props and
  extensibility; `FileReader` (`readAsText`, `readAsDataURL`, `readAsArrayBuffer`, events).
- `drop-files.test.mjs`: a fake `host.fileRead` records `(handle, offset, length)` and answers through
  `__oriel.fileData`. Covers `slice().text()` offsets, a `NotReadableError` rejection, and `fileRelease` after
  dropping references (`node --expose-gc`, as `canvas-clear` does).
- `react-dropzone.test.mjs`: a bundled fixture dir (as with `test/react-real/`) with react-dropzone as a
  devDependency. `onDrop` should receive accepted Files.

**Phase 2:** Win32 and AppKit drop targets, and UIKit drops on iPad. In-page HTML5 DnD (section 4), which is
JS-only and gets a `dnd-inpage.test.mjs`. Reads move to `core/ThreadPool.zig` with the result posted to the UI
thread. Possibly blob: URLs for `<img>` previews (open question).
**Phase 3:** drags out through OS sessions (section 4), Android first: that completes the ChromeOS checklist item.
**Phase 4:** `webkitGetAsEntry` and directories, file promises
(NSFilePromiseReceiver, CFSTR_FILECONTENTS), and Zig-side access to dropped files.

## Risks

| Risk | L | I | Mitigation |
|---|---|---|---|
| Android WebView file-drop behavior unknown | H | M | PoC before phase 4. The native renderer doesn't depend on it. |
| Slow or non-seekable content providers (Drive) | M | M | Open and copy on a worker; deliver drop when ready; `progress` comes later. |
| Large reads stall the UI thread (phase 1 sync pread) | M | M | 64 MiB per call; worker in phase 2; the API is async from day one. |
| Native fields swallow drags (EditText accepts all) | H | M | Field `OnDragListener` forwarding; GTK target on the overlay. |
| Move semantics on async platforms | L | L | Documented: the last over effect decides. |
| fd exhaustion with huge multi-file drops | L | M | Item cap of 4096; release on GC and destroy. |

## Open questions

1. Should Zig app code get access to dropped files, for example `oriel.drop.read(window, handle)` or a path for
   trusted Zig commands, so a page can pass a handle to a command? Electron's `webUtils.getPathForFile` is the
   precedent.
2. Should blob: URLs (`URL.createObjectURL(file)`) work in `<img>`? Image previews in drop zones use them a lot, and
   they need an image source path in each backend.
3. Should `<input type=file>` be in scope? It would reuse `dialog` plus the handle table. react-dropzone's
   click-to-open needs it.
4. What is the maximum single `arrayBuffer()` size before refusing with `NotReadableError`?
5. Should WebView2's `AllowExternalDrop` be exposed as a config flag, plus a native-renderer equivalent ("this app
   accepts no drops")?
6. Are directories in phase 1 skipped (proposed), or delivered as zero-size Files the way Chrome does?
