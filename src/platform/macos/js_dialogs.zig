//! JavaScript `alert()`, `confirm()` and `prompt()` for WKWebView: the
//! WKUIDelegate panel methods, shown as an NSAlert sheet on the page's
//! window (app-modal if the view has no window).
//!
//! WebKit hands us a completion block that must be called exactly once.
//! The sheet's own completion is a block we create, carrying a `Sheet`: a
//! copy of WebKit's handler and the retained alert (which keeps the prompt's
//! text field), freed when the sheet ends.

const std = @import("std");
const apple = @import("../apple/apple.zig");

const Object = apple.Object;

const NSAlertFirstButtonReturn: isize = 1000;

const Kind = enum(u8) { alert, confirm, prompt };

/// What the sheet's completion block carries (owned; freed by `onSheetEnd`).
const Sheet = struct {
    /// WebKit's completion block (copied).
    handler: apple.id,
    /// Retained; keeps the prompt's text field (its accessory view).
    alert: Object,
    /// The prompt's text field, else nil.
    field: Object,
    kind: Kind,
};

/// WKUIDelegate methods for `apple.defineClass`.
pub const methods = .{
    .{ "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:", runAlert },
    .{ "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:", runConfirm },
    .{ "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:", runPrompt },
};

fn runAlert(_: apple.id, _: apple.c.SEL, view: apple.id, message: apple.id, _: apple.id, handler: apple.id) callconv(.c) void {
    show(.alert, view, message, null, handler);
}

fn runConfirm(_: apple.id, _: apple.c.SEL, view: apple.id, message: apple.id, _: apple.id, handler: apple.id) callconv(.c) void {
    show(.confirm, view, message, null, handler);
}

fn runPrompt(_: apple.id, _: apple.c.SEL, view: apple.id, prompt: apple.id, default_text: apple.id, _: apple.id, handler: apple.id) callconv(.c) void {
    show(.prompt, view, prompt, default_text, handler);
}

fn addButton(alert: Object, title: []const u8) void {
    const t = apple.nsString(title) orelse return;
    defer t.release();
    _ = alert.msgSend(Object, "addButtonWithTitle:", .{t});
}

fn show(kind: Kind, view_id: apple.id, message: apple.id, default_text: apple.id, handler: apple.id) void {
    const alert = apple.new(apple.class("NSAlert"));
    defer alert.release(); // the `Sheet` keeps it while it is up
    const view: Object = .{ .value = view_id };
    // Title: the page's title, like browsers show the origin.
    const title = view.msgSend(Object, "title", .{});
    if (title.value != null and title.msgSend(c_ulong, "length", .{}) > 0) {
        alert.msgSend(void, "setMessageText:", .{title});
        alert.msgSend(void, "setInformativeText:", .{Object{ .value = message }});
    } else {
        alert.msgSend(void, "setMessageText:", .{Object{ .value = message }});
    }
    addButton(alert, "OK");
    if (kind != .alert) addButton(alert, "Cancel");

    var field: Object = apple.nil;
    if (kind == .prompt) {
        field = apple.class("NSTextField").msgSend(Object, "alloc", .{})
            .msgSend(Object, "initWithFrame:", .{apple.NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 260, .height = 24 } }});
        if (default_text != null) field.msgSend(void, "setStringValue:", .{Object{ .value = default_text }});
        alert.msgSend(void, "setAccessoryView:", .{field});
        field.release(); // the alert keeps it
        alert.msgSend(void, "layout", .{});
        alert.msgSend(Object, "window", .{}).msgSend(void, "setInitialFirstResponder:", .{field});
    }

    const sheet = std.heap.smp_allocator.create(Sheet) catch {
        // Answer like a dismissed dialog.
        answer(kind, handler, false, null);
        return;
    };
    sheet.* = .{ .handler = apple.copyBlock(handler), .alert = alert.retain(), .field = field, .kind = kind };
    var block = apple.contextBlock(onSheetEnd, sheet);
    const window = view.msgSend(Object, "window", .{});
    if (window.value != null) {
        // AppKit copies the (stack) block; the sheet ends exactly once.
        alert.msgSend(void, "beginSheetModalForWindow:completionHandler:", .{ window, block.ptr() });
    } else {
        onSheetEnd(&block, alert.msgSend(isize, "runModal", .{}));
    }
}

/// The sheet ended with `response` (NSModalResponse): answer WebKit, free the sheet.
fn onSheetEnd(block: *apple.ContextBlock, response: isize) callconv(.c) void {
    const sheet: *Sheet = @ptrCast(@alignCast(block.ctx.?));
    defer {
        apple.releaseBlock(sheet.handler);
        sheet.alert.release();
        std.heap.smp_allocator.destroy(sheet);
    }
    const ok = response == NSAlertFirstButtonReturn;
    const text: apple.id = if (ok and sheet.field.value != null) sheet.field.msgSend(Object, "stringValue", .{}).value else null;
    answer(sheet.kind, sheet.handler, ok, text);
}

/// Call WebKit's completion handler: OK/Cancel for confirm, the text for prompt.
fn answer(kind: Kind, handler: apple.id, ok: bool, text: apple.id) void {
    switch (kind) {
        .alert => apple.callBlock(handler, &.{}, .{}),
        .confirm => apple.callBlock(handler, &.{apple.c.BOOL}, .{apple.boolean(ok)}),
        .prompt => apple.callBlock(handler, &.{apple.id}, .{text}),
    }
}

test {
    std.testing.refAllDecls(@This());
}
