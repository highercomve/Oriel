//! What a -Dnative_ui build has in place of WebKitGTK's bindings: it links
//! no WebKit, so a window's `web_view` is always null. The platform code
//! keeps its `if (web_view) |view| ...` paths; this names their types.

pub const WebView = opaque {
    pub fn evaluateJavascript(_: *WebView, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype) void {
        unreachable; // no web view exists in a native_ui build
    }
};
