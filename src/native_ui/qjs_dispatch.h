// Typed calls into the renderer: no generated JavaScript source to compile.
#ifndef ORIEL_QJS_DISPATCH_H
#define ORIEL_QJS_DISPATCH_H
#include "quickjs.h"
#include <string.h>

// Consumes every argument, including when argument creation failed.
static JSValue nui_dispatch(JSContext *ctx, const char *name, int argc, JSValue *args) {
    JSValue result = JS_EXCEPTION;
    for (int i = 0; i < argc; i++)
        if (JS_IsException(args[i])) goto done;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue receiver = JS_GetPropertyStr(ctx, global, "__oriel");
    JS_FreeValue(ctx, global);
    if (!JS_IsException(receiver)) {
        JSValue fn = JS_GetPropertyStr(ctx, receiver, name);
        if (!JS_IsException(fn)) result = JS_Call(ctx, fn, receiver, argc, args);
        JS_FreeValue(ctx, fn);
    }
    JS_FreeValue(ctx, receiver);
done:
    for (int i = 0; i < argc; i++) JS_FreeValue(ctx, args[i]);
    return result;
}

static JSValue nui_event(JSContext *ctx, int64_t id, const char *kind, size_t kind_len,
                         const char *json, size_t json_len) {
    JSValue data;
    if (json_len == 4 && memcmp(json, "null", 4) == 0) {
        data = JS_NULL;
    } else {
        // QuickJS's JSON scanner requires a terminating byte, even with a length.
        char *terminated = js_malloc(ctx, json_len + 1);
        if (!terminated) return JS_EXCEPTION;
        memcpy(terminated, json, json_len);
        terminated[json_len] = 0;
        data = JS_ParseJSON(ctx, terminated, json_len, "<native event>");
        js_free(ctx, terminated);
    }
    // Check data before allocating strings: preserve its pending exception.
    if (JS_IsException(data)) return data;
    JSValue args[] = { JS_NewInt64(ctx, id), JS_NewStringLen(ctx, kind, kind_len), data };
    return nui_dispatch(ctx, "event", 3, args);
}

static JSValue nui_number_call(JSContext *ctx, const char *name, double value) {
    JSValue arg = JS_NewFloat64(ctx, value);
    return nui_dispatch(ctx, name, 1, &arg);
}
#endif
