//! JavaScript `alert()`, `confirm()` and `prompt()` for WKWebView: the
//! WKUIDelegate panel methods, shown as an NSAlert sheet on the page's
//! window (app-modal if the view has no window).
//!
//! WebKit hands us a completion block that must be called exactly once.
//! The sheet's own completion is a block we create; it captures WebKit's
//! handler, the alert and (for prompt) the text field as objects, so the
//! block runtime retains them until the sheet closes.

const std = @import("std");
const cocoa = @import("cocoa.zig");

const Object = cocoa.Object;
const objc = cocoa.objc;

const NSAlertFirstButtonReturn: i64 = 1000;

const Kind = enum(u8) { alert, confirm, prompt };

const SheetBlock = objc.Block(struct {
    handler: cocoa.id, // WebKit's completion block
    alert: cocoa.id,
    field: cocoa.id, // the prompt's text field (the alert for alert/confirm)
    kind: u8,
}, .{i64}, void); // NSModalResponse (NSInteger; i64: zig-objc encodes it)

/// WKUIDelegate methods for `cocoa.defineClass`.
pub const methods = .{
    .{ "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:", runAlert },
    .{ "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:", runConfirm },
    .{ "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:", runPrompt },
};

fn runAlert(_: cocoa.id, _: cocoa.c.SEL, view: cocoa.id, message: cocoa.id, _: cocoa.id, handler: cocoa.id) callconv(.c) void {
    show(.alert, view, message, null, handler);
}

fn runConfirm(_: cocoa.id, _: cocoa.c.SEL, view: cocoa.id, message: cocoa.id, _: cocoa.id, handler: cocoa.id) callconv(.c) void {
    show(.confirm, view, message, null, handler);
}

fn runPrompt(_: cocoa.id, _: cocoa.c.SEL, view: cocoa.id, prompt: cocoa.id, default_text: cocoa.id, _: cocoa.id, handler: cocoa.id) callconv(.c) void {
    show(.prompt, view, prompt, default_text, handler);
}

fn addButton(alert: Object, title: []const u8) void {
    const t = cocoa.nsString(title) orelse return;
    defer t.release();
    _ = alert.msgSend(Object, "addButtonWithTitle:", .{t});
}

fn show(kind: Kind, view_id: cocoa.id, message: cocoa.id, default_text: cocoa.id, handler: cocoa.id) void {
    const alert = cocoa.new(cocoa.class("NSAlert"));
    defer alert.release(); // the sheet block (or runModal below) keeps it while it's up
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

    var field: Object = cocoa.nil;
    if (kind == .prompt) {
        field = cocoa.class("NSTextField").msgSend(Object, "alloc", .{})
            .msgSend(Object, "initWithFrame:", .{cocoa.NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 260, .height = 24 } }});
        if (default_text != null) field.msgSend(void, "setStringValue:", .{Object{ .value = default_text }});
        alert.msgSend(void, "setAccessoryView:", .{field});
        field.release(); // the alert keeps it
        alert.msgSend(void, "layout", .{});
        alert.msgSend(Object, "window", .{}).msgSend(void, "setInitialFirstResponder:", .{field});
    }

    // Captured objects must be non-nil (the block runtime retains them):
    // without a text field, the alert stands in (never read then).
    const field_capture = if (field.value != null) field.value else alert.value;
    var block = SheetBlock.init(.{ .handler = handler, .alert = alert.value, .field = field_capture, .kind = @intFromEnum(kind) }, &onSheetEnd);
    const window = view.msgSend(Object, "window", .{});
    if (window.value != null) {
        // Copies the (stack) block, retaining its captured objects.
        alert.msgSend(void, "beginSheetModalForWindow:completionHandler:", .{ window, @as(cocoa.id, @ptrCast(&block)) });
    } else {
        onSheetEnd(&block, alert.msgSend(i64, "runModal", .{}));
    }
}

fn onSheetEnd(ctx: *const SheetBlock.Context, response: i64) callconv(.c) void {
    const ok = response == NSAlertFirstButtonReturn;
    switch (@as(Kind, @enumFromInt(ctx.kind))) {
        .alert => cocoa.callBlock(ctx.handler, struct {}, .{}),
        .confirm => cocoa.callBlock(ctx.handler, struct { cocoa.c.BOOL }, .{cocoa.boolean(ok)}),
        .prompt => {
            const text: cocoa.id = if (ok) (Object{ .value = ctx.field }).msgSend(Object, "stringValue", .{}).value else null;
            cocoa.callBlock(ctx.handler, struct { cocoa.id }, .{text});
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
