// Compiles the native renderer's runtime.js to QuickJS bytecode at build
// time (build.zig, addNativeUi): the engine loads it instead of parsing and
// compiling ~650 KB of JavaScript on every window open.
//
//   qjs_bytecode <in.js> <out.qjsbc>
//
// Built for the build machine from the same QuickJS source as the app
// (src/native_ui/vendor/quickjs-ng): its bytecode format is the same on
// every target (QuickJS writes it independent of pointer size; all of
// Oriel's targets are little-endian).

#include <stdio.h>
#include <stdlib.h>
#include "quickjs.h"

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    char *buf = malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
    fclose(f);
    buf[n] = 0; // JS_Eval reads up to a NUL
    *len = (size_t)n;
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <in.js> <out.qjsbc>\n", argv[0]);
        return 2;
    }
    size_t len = 0;
    char *code = read_file(argv[1], &len);
    if (!code) { perror(argv[1]); return 1; }
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = rt ? JS_NewContext(rt) : NULL;
    if (!ctx) { fprintf(stderr, "qjs_bytecode: out of memory\n"); return 1; }
    int status = 1;
    // The name is what stack traces show, as when the engine evaluated the source.
    JSValue fn = JS_Eval(ctx, code, len, "runtime.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(fn)) {
        JSValue e = JS_GetException(ctx);
        const char *msg = JS_ToCString(ctx, e);
        fprintf(stderr, "qjs_bytecode: %s: %s\n", argv[1], msg ? msg : "(exception)");
        if (msg) JS_FreeCString(ctx, msg);
        JS_FreeValue(ctx, e);
    } else {
        size_t size = 0;
        uint8_t *bc = JS_WriteObject(ctx, &size, fn, JS_WRITE_OBJ_BYTECODE);
        JS_FreeValue(ctx, fn);
        if (!bc) {
            fprintf(stderr, "qjs_bytecode: JS_WriteObject failed\n");
        } else {
            FILE *out = fopen(argv[2], "wb");
            if (!out) perror(argv[2]);
            else {
                if (fwrite(bc, 1, size, out) == size && fclose(out) == 0) status = 0;
                else perror(argv[2]);
            }
            js_free(ctx, bc);
        }
    }
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    free(code);
    return status;
}
