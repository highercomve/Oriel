const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("quickjs.h");
    @cInclude("yoga/Yoga.h");
});

fn refuse(ctx: ?*c.JSContext) callconv(.c) c.JSValue {
    return c.JS_ThrowTypeError(ctx, "refused");
}

test "a context that refuses eval: eval, indirect eval and Function throw, the host's eval runs" {
    const rt = c.JS_NewRuntime() orelse return error.NoRuntime;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NoContext;
    defer c.JS_FreeContext(ctx);
    c.JS_OrielSetEvalRefused(ctx, refuse);
    const src =
        \\const r = [];
        \\for (const f of [() => eval("1"), () => (0, eval)("2"), () => new Function("return 3")(),
        \\    () => Function.prototype.constructor("return 4")(), () => (async function () {}).constructor("return 5")]) {
        \\  try { f(); r.push("ran"); } catch (e) { r.push(e.message); }
        \\}
        \\r.push(String(eval(42)));
        \\r.join(",")
    ;
    const v = c.JS_Eval(ctx, src, src.len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, v);
    const s = c.JS_ToCString(ctx, v);
    defer c.JS_FreeCString(ctx, s);
    try std.testing.expectEqualStrings("refused,refused,refused,refused,refused,42", std.mem.span(s));
}

test "quickjs and yoga link" {
    const rt = c.JS_NewRuntime() orelse return error.NoRuntime;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NoContext;
    defer c.JS_FreeContext(ctx);
    const src = "[1,2,3].map(x => x * 2).join(',')";
    const v = c.JS_Eval(ctx, src, src.len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, v);
    const s = c.JS_ToCString(ctx, v);
    defer c.JS_FreeCString(ctx, s);
    try std.testing.expectEqualStrings("2,4,6", std.mem.span(s));

    const root = c.YGNodeNew();
    defer c.YGNodeFreeRecursive(root);
    c.YGNodeStyleSetWidth(root, 300);
    c.YGNodeStyleSetFlexDirection(root, c.YGFlexDirectionRow);
    const a = c.YGNodeNew();
    c.YGNodeStyleSetFlexGrow(a, 1);
    const b = c.YGNodeNew();
    c.YGNodeStyleSetWidth(b, 100);
    c.YGNodeInsertChild(root, a, 0);
    c.YGNodeInsertChild(root, b, 1);
    c.YGNodeCalculateLayout(root, c.YGUndefined, c.YGUndefined, c.YGDirectionLTR);
    try std.testing.expectEqual(@as(f32, 200), c.YGNodeLayoutGetWidth(a));
    try std.testing.expectEqual(@as(f32, 200), c.YGNodeLayoutGetLeft(b));
}
