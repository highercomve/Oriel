// dom_bench: runs a script against the native DOM (docs/native-dom.md) or
// linkedom, in the vendored QuickJS.
//   dom_bench bench.js                    the native DOM
//   dom_bench bench.js linkedom.iife.js   linkedom (the bundle defines parseHTML)
// ROWS=3000 dom_bench … sets globalThis.ROWS.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"
#include "dom_qjs.h"

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)n + 1);
    if (b && fread(b, 1, (size_t)n, f) == (size_t)n) { b[n] = 0; *len = (size_t)n; }
    else { free(b); b = NULL; }
    fclose(f);
    return b;
}

static JSValue js_print(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    for (int i = 0; i < argc; i++) {
        const char *s = JS_ToCString(ctx, argv[i]);
        if (s) { fputs(s, stdout); JS_FreeCString(ctx, s); }
    }
    fputc('\n', stdout);
    return JS_UNDEFINED;
}

// gc(): a cycle collection now (tests).
static JSValue js_gc(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    JS_RunGC(JS_GetRuntime(ctx));
    return JS_UNDEFINED;
}

static int eval_file(JSContext *ctx, const char *path) {
    size_t len;
    char *code = read_file(path, &len);
    if (!code) { perror(path); return -1; }
    JSValue r = JS_Eval(ctx, code, len, path, JS_EVAL_TYPE_GLOBAL);
    free(code);
    if (JS_IsException(r)) {
        JSValue e = JS_GetException(ctx);
        const char *m = JS_ToCString(ctx, e);
        JSValue st = JS_GetPropertyStr(ctx, e, "stack");
        const char *s = JS_ToCString(ctx, st);
        fprintf(stderr, "%s: %s\n%s\n", path, m ? m : "?", s ? s : "");
        JS_FreeCString(ctx, m);
        JS_FreeCString(ctx, s);
        JS_FreeValue(ctx, st);
        JS_FreeValue(ctx, e);
        return -1;
    }
    JS_FreeValue(ctx, r);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s bench.js [linkedom.iife.js]\n", argv[0]); return 2; }
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = JS_NewContext(rt);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "print", JS_NewCFunction(ctx, js_print, "print", 1));
    JS_SetPropertyStr(ctx, global, "gc", JS_NewCFunction(ctx, js_gc, "gc", 0));
    const char *rows = getenv("ROWS");
    if (rows) JS_SetPropertyStr(ctx, global, "ROWS", JS_NewInt32(ctx, atoi(rows)));
    // atob for linkedom's entity tables
    JS_FreeValue(ctx, JS_Eval(ctx, "globalThis.atob ??= (s) => { const a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; let o = '', b = 0, n = 0; for (const c of String(s).replace(/[^A-Za-z0-9+/]/g, '')) { b = (b << 6) | a.indexOf(c); n += 6; if (n >= 8) { n -= 8; o += String.fromCharCode((b >> n) & 255); } } return o; };", 300, "<atob>", JS_EVAL_TYPE_GLOBAL));
    DomCtx *dc = NULL;
    int status = 0;
    if (argc > 2) {
        status = eval_file(ctx, argv[2]);
    } else {
        dc = nui_dom_install(ctx);
        if (!dc) { fprintf(stderr, "dom install failed\n"); return 1; }
        JS_SetPropertyStr(ctx, global, "document", nui_dom_document_object(dc));
    }
    JS_FreeValue(ctx, global);
    if (!status) status = eval_file(ctx, argv[1]);
    // The page's references first, then the DOM, then the context.
    JSValue g = JS_GetGlobalObject(ctx);
    JSAtom doc = JS_NewAtom(ctx, "document");
    JS_DeleteProperty(ctx, g, doc, 0);
    JS_FreeAtom(ctx, doc);
    JS_FreeValue(ctx, g);
    JS_RunGC(rt);
    if (dc) nui_dom_uninstall(dc);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return status ? 1 : 0;
}
