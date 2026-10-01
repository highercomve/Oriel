//! JavaScript `alert()`, `confirm()` and `prompt()` for WKWebView on iOS: the
//! WKUIDelegate panel methods, shown as a UIAlertController presented by the
//! page's view controller. WebKit's completion block is called exactly once,
//! from the tapped action (the alert can't be dismissed otherwise).
//!
//! Ownership: each action's handler block owns its `Pending` (the action's
//! arguments) through the block's copy/dispose helpers, so teardown follows
//! exactly the live copies — however the alert ends. UIKit retains a copied
//! block for as long as the alert does, and the last copy released drops the
//! shared dialog state, WebKit's copied completion handler and the alert's
//! own retain. A dialog that dies without an answer (the alert released
//! without an action firing) still tears everything down; nothing needs the
//! OK action to fire to clean up. The alert pointer is borrowed, never
//! strongly held by the blocks, so no retain cycle.

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

/// What an action's block owns (freed dispose-helper by dispose-helper):
/// the action's arguments and, for the last one, the dialog's shared state.
const Pending = struct {
    kind: Kind,
    /// WebKit's copied completion handler (owned by `Shared`).
    handler: apple.id,
    /// For the OK action's prompt text field. Borrowed: the alert exists
    /// while its action blocks exist, and a released block can't be
    /// invoked.
    alert: apple.id,
    ok: bool,
    /// One completion, refcounted by the live copies of its action blocks
    /// plus `show`'s own ownership of the alert (dropped last).
    shared: *Shared,
};

const Shared = struct {
    /// Whichever action runs first answers WebKit; the others are late.
    done: bool = false,
    /// Live copies of the action blocks plus `show`'s retain.
    refs: u32,
};

fn finish(block: *apple.ManagedBlock, _: apple.id) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(block.ctx.?));
    if (p.shared.done) return;
    p.shared.done = true;
    switch (p.kind) {
        .alert => apple.callBlock(p.handler, &.{}, .{}),
        .confirm => apple.callBlock(p.handler, &.{apple.c.BOOL}, .{apple.boolean(p.ok)}),
        .prompt => {
            var text: apple.id = null;
            if (p.ok) {
                const fields = (Object{ .value = p.alert }).msgSend(Object, "textFields", .{});
                if (fields.value != null and fields.msgSend(c_ulong, "count", .{}) > 0)
                    text = fields.msgSend(Object, "objectAtIndex:", .{@as(c_ulong, 0)}).msgSend(Object, "text", .{}).value;
            }
            apple.callBlock(p.handler, &.{apple.id}, .{text});
        },
    }
}

/// Per live copy of an action block: one refcount up.
fn actionCopy(_: *apple.BlockLiteral, src: *apple.BlockLiteral) callconv(.c) void {
    const block: *apple.ManagedBlock = @ptrCast(@alignCast(src));
    const p: *Pending = @ptrCast(@alignCast(block.ctx.?));
    p.shared.refs += 1;
}

fn actionDispose(src: *apple.BlockLiteral) callconv(.c) void {
    const block: *apple.ManagedBlock = @ptrCast(@alignCast(src));
    const p: *Pending = @ptrCast(@alignCast(block.ctx.?));
    p.shared.refs -= 1;
    if (p.shared.refs == 0) {
        apple.releaseBlock(p.handler);
        (Object{ .value = p.alert }).release();
        std.heap.smp_allocator.destroy(p.shared);
    }
    std.heap.smp_allocator.destroy(p);
}

const UIAlertControllerStyleAlert: isize = 1;
const UIAlertActionStyleDefault: isize = 0;
const UIAlertActionStyleCancel: isize = 1;

fn addAction(alert: apple.id, kind: Kind, handler: apple.id, shared: *Shared, title: []const u8, ok: bool) void {
    const p = std.heap.smp_allocator.create(Pending) catch {
        shared.refs -= 1; // the last copy out frees the dialog
        return;
    };
    p.* = .{ .kind = kind, .handler = handler, .alert = alert, .ok = ok, .shared = shared };
    shared.refs += 1;
    const t = apple.nsString(title) orelse {
        shared.refs -= 1;
        std.heap.smp_allocator.destroy(p);
        return;
    };
    defer t.release();
    var block = apple.managedBlock(finish, p, actionCopy, actionDispose);
    const action = apple.class("UIAlertAction").msgSend(Object, "actionWithTitle:style:handler:", .{
        t, if (ok) UIAlertActionStyleDefault else UIAlertActionStyleCancel, block.ptr(),
    });
    (Object{ .value = alert }).msgSend(void, "addAction:", .{action});
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
    shared.* = .{ .refs = 1 }; // show's own ownership of the alert
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
    if (kind != .alert) addAction(alert.value, kind, handler, shared, "Cancel", false);
    addAction(alert.value, kind, handler, shared, "OK", true);
    controller.msgSend(void, "presentViewController:animated:completion:", .{ alert, apple.boolean(true), @as(apple.id, null) });
}
