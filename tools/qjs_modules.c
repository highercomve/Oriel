// The QuickJS half of tools/qjs_modules.zig: one ES module compiled to
// bytecode (JS_WriteObject), named as the engine names it (its asset
// path), so the engine reads it instead of parsing (qjs_shim.c).
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"

static JSRuntime *rt;
static JSContext *ctx;

// 0 and *out (free with free()) on success; -1 when it doesn't compile
// as a module (the engine then compiles it itself, as before).
int oriel_qjs_compile_module(const char *code, size_t len, const char *name, unsigned char **out, size_t *out_len) {
    if (!ctx) {
        rt = JS_NewRuntime();
        ctx = rt ? JS_NewContext(rt) : NULL;
        if (!ctx) return -1;
    }
    // JS_Eval reads up to a NUL.
    char *src = malloc(len + 1);
    if (!src) return -1;
    memcpy(src, code, len);
    src[len] = 0;
    JSValue fn = JS_Eval(ctx, src, len, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(src);
    if (JS_IsException(fn)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        return -1;
    }
    size_t size = 0;
    uint8_t *bc = JS_WriteObject(ctx, &size, fn, JS_WRITE_OBJ_BYTECODE);
    JS_FreeValue(ctx, fn);
    if (!bc) return -1;
    *out = malloc(size);
    if (!*out) { js_free(ctx, bc); return -1; }
    memcpy(*out, bc, size);
    *out_len = size;
    js_free(ctx, bc);
    return 0;
}
