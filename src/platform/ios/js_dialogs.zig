//! JavaScript `alert()`, `confirm()` and `prompt()` for WKWebView on iOS: the
//! WKUIDelegate panel methods, shown as a UIAlertController presented by the
//! page's view controller. WebKit's completion block is called exactly once,
//! from the tapped action (the alert can't be dismissed otherwise).
//!
//! Ownership: each heap copy of an action's handler block owns its own
//! `Pending` (the action's arguments) through the block's copy/dispose
//! helpers; the stack block `addAction` builds owns the one it frees itself.
//! `Shared.refs` counts the live heap copies only. UIKit keeps them for as
//! long as the alert, which the presenting controller retains while it is on
//! screen, so the last copy released (the alert gone, however it ended)
//! drops the shared state and WebKit's copied completion handler, answering
//! WebKit first if no action ran (it raises when a completion handler is
//! released uncalled). The alert pointer is borrowed, never strongly held by
//! the blocks, so no retain cycle.

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
    /// One completion, refcounted by the live heap copies of its action blocks.
    shared: *Shared,
};

const Shared = struct {
    /// Whichever action runs first answers WebKit; the others are late.
    done: bool = false,
    /// Live heap copies of the action blocks.
    refs: u32 = 0,
};

fn finish(block: *apple.ManagedBlock, _: apple.id) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(block.ctx orelse return));
    if (p.shared.done) return;
    p.shared.done = true;
    var text: apple.id = null;
    if (p.kind == .prompt and p.ok) {
        const fields = (Object{ .value = p.alert }).msgSend(Object, "textFields", .{});
        if (fields.value != null and fields.msgSend(c_ulong, "count", .{}) > 0)
            text = fields.msgSend(Object, "objectAtIndex:", .{@as(c_ulong, 0)}).msgSend(Object, "text", .{}).value;
    }
    answer(p.kind, p.handler, p.ok, text);
}

/// Call WebKit's completion handler: OK/Cancel for confirm, the text for prompt.
fn answer(kind: Kind, handler: apple.id, ok: bool, text: apple.id) void {
    switch (kind) {
        .alert => apple.callBlock(handler, &.{}, .{}),
        .confirm => apple.callBlock(handler, &.{apple.c.BOOL}, .{apple.boolean(ok)}),
        .prompt => apple.callBlock(handler, &.{apple.id}, .{text}),
    }
}

/// A heap copy of an action block (the runtime has copied `src` into `dst`):
/// its own `Pending`, and one refcount up. Out of memory, the copy carries
/// none and does nothing.
fn actionCopy(dst: *apple.BlockLiteral, src: *apple.BlockLiteral) callconv(.c) void {
    const from: *apple.ManagedBlock = @ptrCast(@alignCast(src));
    const to: *apple.ManagedBlock = @ptrCast(@alignCast(dst));
    to.ctx = null;
    const p: *Pending = @ptrCast(@alignCast(from.ctx orelse return));
    const own = std.heap.smp_allocator.create(Pending) catch return;
    own.* = p.*;
    p.shared.refs += 1;
    to.ctx = own;
}

/// A heap copy released: the last one answers WebKit if no action ran, then
/// frees the dialog.
fn actionDispose(src: *apple.BlockLiteral) callconv(.c) void {
    const block: *apple.ManagedBlock = @ptrCast(@alignCast(src));
    const p: *Pending = @ptrCast(@alignCast(block.ctx orelse return));
    const shared = p.shared;
    shared.refs -= 1;
    if (shared.refs == 0) {
        if (!shared.done) answer(p.kind, p.handler, false, null);
        apple.releaseBlock(p.handler);
        std.heap.smp_allocator.destroy(shared);
    }
    std.heap.smp_allocator.destroy(p);
}

const UIAlertControllerStyleAlert: isize = 1;
const UIAlertActionStyleDefault: isize = 0;
const UIAlertActionStyleCancel: isize = 1;

fn addAction(alert: apple.id, kind: Kind, handler: apple.id, shared: *Shared, title: []const u8, ok: bool) void {
    // The stack block's own `Pending`: UIKit copies the block (actionCopy
    // gives the copy its own) before actionWithTitle returns.
    var p: Pending = .{ .kind = kind, .handler = handler, .alert = alert, .ok = ok, .shared = shared };
    const t = apple.nsString(title) orelse return;
    defer t.release();
    var block = apple.managedBlock(finish, &p, actionCopy, actionDispose);
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
    // Ours until presented: the presenting controller retains it then.
    const alert = apple.class("UIAlertController").msgSend(Object, "alertControllerWithTitle:message:preferredStyle:", .{
        title, Object{ .value = message }, UIAlertControllerStyleAlert,
    }).retain();
    defer alert.release();
    const shared = std.heap.smp_allocator.create(Shared) catch {
        answer(kind, handler, false, null);
        apple.releaseBlock(handler);
        return;
    };
    shared.* = .{};
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
    if (shared.refs == 0) {
        // No action could be added: answer like a dismissed dialog.
        answer(kind, handler, false, null);
        apple.releaseBlock(handler);
        std.heap.smp_allocator.destroy(shared);
        return;
    }
    controller.msgSend(void, "presentViewController:animated:completion:", .{ alert, apple.boolean(true), @as(apple.id, null) });
}
