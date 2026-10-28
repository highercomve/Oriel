<!-- Generated from site/content/docs/video.smd by tools/docs/gen-md.mjs: edit that file. -->

# Video

A native video player over the window, for what the WebView's <video> can't play: camcorder MPEG-TS, WMV, ProRes, or a GPU where the WebView's video is slow.

`oriel.video` shows a **native video player** over the app's window: the
video fills the window, with the platform's own controls (play, pause,
seek, volume), the title at the top and a close button. Closing it (that
button, Esc, Android's back) shows the page again, as it was.

A `<video>` element plays only what the WebView accepts. WebKitGTK refuses
MPEG-TS from camcorders (`.mts`, `.m2ts`), WMV/ASF and ProRes even when
GStreamer on the system plays them, and on some NVIDIA setups it can't
show video smoothly. The native player plays what the platform plays,
drawn by the GPU.

## Availability

| Platform | Player | URLs it takes |
|---|---|---|
| Linux | `GtkVideo` on a `GtkMediaFile` (GStreamer), graphics offload on GTK 4.14+ | `http(s)://` (the [media server](media-server.md)'s), `file://` |
| Android | `MediaPlayer` on a `SurfaceView`, with a `MediaController` | `http(s)://`, `file://`, `content://`, the app's media URLs (`https://app.localhost/media/...`) |
| Windows, macOS, iOS | — (`available` is false) | |

The module is the `video` flag, **on by default** where it exists. With
the native renderer (`native_ui`) it is off: the player goes over a
WebView window. The page sees `window.oriel.features.video` and
`oriel.video.available`.

- **Linux** plays what the installed GStreamer plugins decode (`gst-libav`
  for most codecs, `gst-plugins-good` for http). GtkVideo's graphics
  offload lets the compositor show frames without a copy, where the
  compositor and driver can.
- **Android** plays what `MediaPlayer` decodes (the device's codecs).
  Plain `http://` needs the app's network security config to allow
  cleartext to that host.
- **One player at a time.** `play` while one shows plays the new URL in
  it (no `video:closed` for the old one).

## From the page

```js
if (oriel.video.available) {
  await oriel.video.play({ url, title: "Beach, 2019" }); // resolves once it shows
}
oriel.listen("video:ended", ({ url }) => { /* played to the end; still showing */ });
oriel.listen("video:error", ({ url, message }) => { /* the platform's message */ });
oriel.listen("video:closed", ({ url }) => { /* the page shows again */ });
oriel.video.close(); // closes it from the page, if one shows
```

`play` rejects with `"Unsupported"` (not in this build or on this
platform), `"InvalidUrl"` (a scheme the player can't open), `"NoWindow"`
or `"Failed"` (Android: the app media path isn't there). A file that
can't be decoded, or a server that answers 404, shows the player and then
sends `video:error`: the player stays until it is closed, by the user or
by `oriel.video.close()`. The events go to every window; each carries the
URL it is about.

`play` covers the window that called it. The types are in the generated
`oriel.ts` (`VideoApi`, `VideoPlayOptions`, `VideoEvent`).

## From Zig

```zig
if (oriel.video.available) {
    try oriel.video.play(null, .{ .url = url, .title = "Beach, 2019" });
}
oriel.video.close();
```

`play(window, options)`: `window` is an `*oriel.App.Window` (null: the
focused window, else `"main"`). It returns once the player shows, from any
thread (it waits for the main thread). The same events reach the page.

## Examples

### Desktop: a media source over the media server

The [media server](media-server.md) serves the app's bytes
with HTTP Range; GStreamer seeks with it. Here `library` is a
[`Source`](media-server.md#source).

```zig
try media.start(io, gpa, .{ .root_dir = "", .port = 17893, .source = library.source() });
```

```js
await oriel.video.play({ url: "http://127.0.0.1:17893/clips/00012.mts", title: "00012.MTS" });
```

A local file needs no server: `file:///home/me/Videos/00012.MTS`.

### Android: the app's media URLs

`https://app.localhost/media/<path>` ([`media_scheme.base_url`](media-server.md)) exists only inside the
WebView, which `MediaPlayer` can't ask. The player reads it in-process
instead, the way the WebView gets it: from the media source set with
`media_scheme.setSource` (its `readFn` is called on MediaPlayer's thread,
as the source contract allows), else from the file below the root set
with `media_scheme.setRoot`.

```zig
oriel.media_scheme.setSource(library.source()) catch |err|
    std.log.warn("media source: {s}", .{@errorName(err)});
```

```js
await oriel.video.play({ url: "https://app.localhost/media/clips/00012.mts", title: "00012.MTS" });
```

Other paths on the app's origin are refused (`"InvalidUrl"`): only its
media are files.

## Related

- [Media server](media-server.md): serving local files and media sources with Range.
- [Desktop](desktop.md): WebKitGTK on NVIDIA.
- [Modules](modules.md): flags and availability.
