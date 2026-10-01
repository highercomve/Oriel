const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("quickjs.h");
    @cInclude("yoga/Yoga.h");
});

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
