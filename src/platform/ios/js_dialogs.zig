//! JavaScript `alert()`, `confirm()` and `prompt()` for WKWebView on iOS: the
//! WKUIDelegate panel methods, shown as a UIAlertController presented by the
//! page's view controller. WebKit's completion block is called exactly once,
//! from the tapped action (the alert can't be dismissed otherwise).

const std = @import("std");
const apple = @import("apple.zig");
const window = @import("window.zig");

const Object = apple.Object;

const Kind = enum(u8) { alert, confirm, prompt };

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

/// What an action's block needs: WebKit's handler (copied), the alert (for
/// the prompt's text field), whether it is the OK action.
const Pending = struct {
    kind: Kind,
    handler: apple.id,
    alert: Object,
    ok: bool,
    /// The OK and Cancel actions share one completion: whichever runs first.
    shared: *Shared,
};

const Shared = struct {
    done: bool = false,
    refs: u8,
};

fn finish(block: *apple.ContextBlock, _: apple.id) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(block.ctx.?));
    const gpa = std.heap.smp_allocator;
    defer {
        p.shared.refs -= 1;
        if (p.shared.refs == 0) {
            p.alert.release();
            apple.releaseBlock(p.handler);
            gpa.destroy(p.shared);
        }
        gpa.destroy(p);
    }
    if (p.shared.done) return;
    p.shared.done = true;
    switch (p.kind) {
        .alert => apple.callBlock(p.handler, &.{}, .{}),
        .confirm => apple.callBlock(p.handler, &.{apple.c.BOOL}, .{apple.boolean(p.ok)}),
        .prompt => {
            var text: apple.id = null;
            if (p.ok) {
                const fields = p.alert.msgSend(Object, "textFields", .{});
                if (fields.value != null and fields.msgSend(c_ulong, "count", .{}) > 0)
                    text = fields.msgSend(Object, "objectAtIndex:", .{@as(c_ulong, 0)}).msgSend(Object, "text", .{}).value;
            }
            apple.callBlock(p.handler, &.{apple.id}, .{text});
        },
    }
}

const UIAlertControllerStyleAlert: isize = 1;
const UIAlertActionStyleDefault: isize = 0;
const UIAlertActionStyleCancel: isize = 1;

fn addAction(alert: Object, kind: Kind, handler: apple.id, shared: *Shared, title: []const u8, ok: bool) void {
    const p = std.heap.smp_allocator.create(Pending) catch return;
    p.* = .{ .kind = kind, .handler = handler, .alert = alert, .ok = ok, .shared = shared };
    shared.refs += 1;
    const t = apple.nsString(title) orelse return;
    defer t.release();
    var block = apple.contextBlock(finish, p);
    const action = apple.class("UIAlertAction").msgSend(Object, "actionWithTitle:style:handler:", .{
        t, if (ok) UIAlertActionStyleDefault else UIAlertActionStyleCancel, block.ptr(),
    });
    alert.msgSend(void, "addAction:", .{action});
}

fn show(kind: Kind, view_id: apple.id, message: apple.id, default_text: apple.id, handler_arg: apple.id) void {
    const view: Object = .{ .value = view_id };
    const controller = window.controllerForView(view_id) orelse {
        // No window to present on: answer like a dismissed dialog.
        switch (kind) {
            .alert => apple.callBlock(handler_arg, &.{}, .{}),
            .confirm => apple.callBlock(handler_arg, &.{apple.c.BOOL}, .{apple.boolean(false)}),
            .prompt => apple.callBlock(handler_arg, &.{apple.id}, .{null}),
        }
        return;
    };
    const handler = apple.copyBlock(handler_arg);
    const title = view.msgSend(Object, "title", .{});
    const alert = apple.class("UIAlertController").msgSend(Object, "alertControllerWithTitle:message:preferredStyle:", .{
        title, Object{ .value = message }, UIAlertControllerStyleAlert,
    }).retain();
    const shared = std.heap.smp_allocator.create(Shared) catch {
        alert.release();
        apple.releaseBlock(handler);
        return;
    };
    shared.* = .{ .refs = 0 };
    if (kind == .prompt) {
        const Configure = struct {
            fn f(block: *apple.ContextBlock, field: apple.id) callconv(.c) void {
                const text: apple.id = @ptrCast(block.ctx);
                if (text != null) (Object{ .value = field }).msgSend(void, "setText:", .{Object{ .value = text }});
            }
        };
        var block = apple.contextBlock(Configure.f, default_text);
        alert.msgSend(void, "addTextFieldWithConfigurationHandler:", .{block.ptr()});
    }
    if (kind != .alert) addAction(alert, kind, handler, shared, "Cancel", false);
    addAction(alert, kind, handler, shared, "OK", true);
    controller.msgSend(void, "presentViewController:animated:completion:", .{ alert, apple.boolean(true), @as(apple.id, null) });
}
