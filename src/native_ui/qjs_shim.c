// QuickJS-ng for the native renderer (docs/native-renderer.md): one runtime
// and context per window, the page's `__host` object, and plain C entry
// points for Zig (src/native_ui/engine.zig). The host functions call back
// into Zig through the oriel_nui_* functions it exports.

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "quickjs.h"

// Implemented in engine.zig.
extern void oriel_nui_log(void *opaque, int level, const char *msg, size_t len);
extern int oriel_nui_asset(void *opaque, const char *path, size_t len, const char **out, size_t *out_len);
extern void oriel_nui_invoke(void *opaque, uint32_t call_id, const char *cmd, size_t cmd_len, const char *args, size_t args_len);
extern void oriel_nui_timer(void *opaque, uint32_t timer_id, double ms);
extern void oriel_nui_ops(void *opaque, const char *json, size_t len);
extern int oriel_nui_frame(void *opaque, double id, double *out5);
extern void oriel_nui_focus(void *opaque, double id);
extern void oriel_nui_scroll_into_view(void *opaque, double id, const char *block, size_t len);
extern void oriel_nui_scroll_to(void *opaque, double id, double y);

typedef struct {
    JSRuntime *rt;
    JSContext *ctx;
    void *opaque;
} oqjs;

static void *opaque_of(JSContext *ctx) { return JS_GetContextOpaque(ctx); }

// The pending exception, with its stack, to the log.
static void report(JSContext *ctx) {
    JSValue exc = JS_GetException(ctx);
    size_t len = 0;
    const char *msg = JS_ToCStringLen(ctx, &len, exc);
    char buf[4096];
    size_t n = 0;
    if (msg) n = (size_t)snprintf(buf, sizeof buf, "%.*s", (int)len, msg);
    if (JS_IsObject(exc)) {
        JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
        if (!JS_IsUndefined(stack)) {
            size_t slen = 0;
            const char *s = JS_ToCStringLen(ctx, &slen, stack);
            if (s && n < sizeof buf) n += (size_t)snprintf(buf + n, sizeof buf - n, "\n%.*s", (int)slen, s);
            if (s) JS_FreeCString(ctx, s);
        }
        JS_FreeValue(ctx, stack);
    }
    if (n >= sizeof buf) n = sizeof buf - 1;
    oriel_nui_log(opaque_of(ctx), 3, buf, n);
    if (msg) JS_FreeCString(ctx, msg);
    JS_FreeValue(ctx, exc);
}

static JSValue h_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t level = 1;
    if (argc > 0) JS_ToInt32(ctx, &level, argv[0]);
    size_t len = 0;
    const char *s = argc > 1 ? JS_ToCStringLen(ctx, &len, argv[1]) : NULL;
    if (s) { oriel_nui_log(opaque_of(ctx), level, s, len); JS_FreeCString(ctx, s); }
    return JS_UNDEFINED;
}

static JSValue h_asset(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    size_t len = 0;
    const char *p = JS_ToCStringLen(ctx, &len, argv[0]);
    if (!p) return JS_EXCEPTION;
    const char *out = NULL;
    size_t out_len = 0;
    int ok = oriel_nui_asset(opaque_of(ctx), p, len, &out, &out_len);
    JS_FreeCString(ctx, p);
    if (!ok) return JS_UNDEFINED;
    return JS_NewStringLen(ctx, out, out_len);
}

static JSValue h_invoke(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 3) return JS_UNDEFINED;
    uint32_t id = 0;
    JS_ToUint32(ctx, &id, argv[0]);
    size_t clen = 0, alen = 0;
    const char *cmd = JS_ToCStringLen(ctx, &clen, argv[1]);
    const char *args = JS_ToCStringLen(ctx, &alen, argv[2]);
    if (cmd && args) oriel_nui_invoke(opaque_of(ctx), id, cmd, clen, args, alen);
    if (cmd) JS_FreeCString(ctx, cmd);
    if (args) JS_FreeCString(ctx, args);
    return JS_UNDEFINED;
}

static JSValue h_timer(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_UNDEFINED;
    uint32_t id = 0;
    double ms = 0;
    JS_ToUint32(ctx, &id, argv[0]);
    JS_ToFloat64(ctx, &ms, argv[1]);
    oriel_nui_timer(opaque_of(ctx), id, ms);
    return JS_UNDEFINED;
}

static JSValue h_ops(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    size_t len = 0;
    const char *s = JS_ToCStringLen(ctx, &len, argv[0]);
    if (s) { oriel_nui_ops(opaque_of(ctx), s, len); JS_FreeCString(ctx, s); }
    return JS_UNDEFINED;
}

static JSValue h_frame(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    double id = 0, out[5];
    JS_ToFloat64(ctx, &id, argv[0]);
    if (!oriel_nui_frame(opaque_of(ctx), id, out)) return JS_UNDEFINED;
    JSValue arr = JS_NewArray(ctx);
    for (uint32_t i = 0; i < 5; i++) JS_SetPropertyUint32(ctx, arr, i, JS_NewFloat64(ctx, out[i]));
    return arr;
}

static JSValue h_focus(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    double id = 0;
    if (argc > 0) JS_ToFloat64(ctx, &id, argv[0]);
    oriel_nui_focus(opaque_of(ctx), id);
    return JS_UNDEFINED;
}

static JSValue h_scroll_into_view(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    double id = 0;
    if (argc > 0) JS_ToFloat64(ctx, &id, argv[0]);
    size_t len = 0;
    const char *block = argc > 1 ? JS_ToCStringLen(ctx, &len, argv[1]) : NULL;
    oriel_nui_scroll_into_view(opaque_of(ctx), id, block ? block : "start", block ? len : 5);
    if (block) JS_FreeCString(ctx, block);
    return JS_UNDEFINED;
}

static JSValue h_scroll_to(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    double id = 0, y = 0;
    if (argc > 0) JS_ToFloat64(ctx, &id, argv[0]);
    if (argc > 1) JS_ToFloat64(ctx, &y, argv[1]);
    oriel_nui_scroll_to(opaque_of(ctx), id, y);
    return JS_UNDEFINED;
}

static JSValue h_eval_script(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_UNDEFINED;
    size_t nlen = 0, clen = 0;
    const char *name = JS_ToCStringLen(ctx, &nlen, argv[0]);
    const char *code = JS_ToCStringLen(ctx, &clen, argv[1]);
    if (name && code) {
        JSValue r = JS_Eval(ctx, code, clen, name, JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(r)) report(ctx);
        JS_FreeValue(ctx, r);
    }
    if (name) JS_FreeCString(ctx, name);
    if (code) JS_FreeCString(ctx, code);
    return JS_UNDEFINED;
}

static void set_fn(JSContext *ctx, JSValue obj, const char *name, JSCFunction *fn, int len) {
    JS_SetPropertyStr(ctx, obj, name, JS_NewCFunction(ctx, fn, name, len));
}

void *oqjs_new(void *opaque, const char *platform_json, const char *label) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return NULL;
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { JS_FreeRuntime(rt); return NULL; }
    oqjs *self = js_malloc(ctx, sizeof *self);
    self->rt = rt;
    self->ctx = ctx;
    self->opaque = opaque;
    JS_SetContextOpaque(ctx, opaque);
    JS_SetMaxStackSize(rt, 4 * 1024 * 1024);

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue host = JS_NewObject(ctx);
    set_fn(ctx, host, "log", h_log, 2);
    set_fn(ctx, host, "asset", h_asset, 1);
    set_fn(ctx, host, "invoke", h_invoke, 3);
    set_fn(ctx, host, "timer", h_timer, 2);
    set_fn(ctx, host, "ops", h_ops, 1);
    set_fn(ctx, host, "frame", h_frame, 1);
    set_fn(ctx, host, "focus", h_focus, 1);
    set_fn(ctx, host, "scrollIntoView", h_scroll_into_view, 2);
    set_fn(ctx, host, "scrollTo", h_scroll_to, 2);
    set_fn(ctx, host, "evalScript", h_eval_script, 2);
    JS_SetPropertyStr(ctx, host, "platform", JS_NewString(ctx, platform_json));
    JS_SetPropertyStr(ctx, host, "label", JS_NewString(ctx, label));
    JS_SetPropertyStr(ctx, global, "__host", host);
    JS_FreeValue(ctx, global);
    return self;
}

// Run `code` as a global script; 1 if it returned a truthy value, 0 if not,
// -1 on an exception (logged).
int oqjs_eval(void *p, const char *code, size_t len, const char *name) {
    oqjs *self = p;
    JSValue r = JS_Eval(self->ctx, code, len, name, JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(r)) { report(self->ctx); return -1; }
    int truthy = JS_ToBool(self->ctx, r);
    JS_FreeValue(self->ctx, r);
    return truthy > 0 ? 1 : 0;
}

// Run the pending promise jobs (microtasks).
void oqjs_run_jobs(void *p) {
    oqjs *self = p;
    JSContext *job_ctx;
    for (;;) {
        int r = JS_ExecutePendingJob(self->rt, &job_ctx);
        if (r == 0) break;
        if (r < 0) report(job_ctx);
    }
}

size_t oqjs_memory(void *p) {
    oqjs *self = p;
    JSMemoryUsage u;
    JS_ComputeMemoryUsage(self->rt, &u);
    return (size_t)u.memory_used_size;
}

void oqjs_free(void *p) {
    oqjs *self = p;
    JSRuntime *rt = self->rt;
    JSContext *ctx = self->ctx;
    js_free(ctx, self);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
}
