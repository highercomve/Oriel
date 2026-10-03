// QuickJS-ng for the native renderer (docs/native-renderer.md): one runtime
// and context per window, the page's `__host` object, and plain C entry
// points for Zig (src/native_ui/engine.zig). The host functions call back
// into Zig through the oriel_nui_* functions it exports.

#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif
#include "quickjs.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

// How deep the page's JavaScript may recurse, measured from where the
// outermost call from Zig entered: well under the UI thread's stack (1 MB
// on iOS's main thread, 8 MB on macOS, Linux and Android), so runaway
// recursion is a RangeError, not a crash on the guard page.
#if defined(__APPLE__) && TARGET_OS_IPHONE
#define NUI_MAX_STACK (512 * 1024)
#else
#define NUI_MAX_STACK (4 * 1024 * 1024)
#endif

// Implemented in engine.zig.
extern void oriel_nui_log(void *opaque, int level, const char *msg, size_t len);
extern int oriel_nui_asset(void *opaque, const char *path, size_t len, const char **out, size_t *out_len);
extern void oriel_nui_invoke(void *opaque, uint32_t call_id, const char *cmd, size_t cmd_len, const char *args, size_t args_len);
extern void oriel_nui_timer(void *opaque, uint32_t timer_id, double ms);
extern void oriel_nui_ops(void *opaque, const char *json, size_t len);
extern int oriel_nui_text(void *opaque, double id, const char *text, size_t len);
extern int oriel_nui_vsync(void *opaque);
extern void oriel_nui_warm_fonts(void *opaque, const double *v, size_t count);
extern int oriel_nui_font_metrics(void *opaque, double size, int mono, double *out);
extern int oriel_nui_canvas(void *opaque, double id, const double *nums, size_t len, const char *const *strs, const size_t *lens, size_t count);
extern uint32_t oriel_nui_stamp_plan(void *opaque, const double *v, size_t len);
#if defined(ORIEL_NATIVE_DOM)
extern int oriel_nui_stamp(void *opaque, double row_id, void *dom, uint32_t row, uint32_t plan);
extern int oriel_nui_stamp_list(void *opaque, double list_id, void *dom, uint32_t list, double row_style, uint32_t plan,
                                uint32_t template_row, const uint32_t *kept, size_t kept_len);
#endif
extern int oriel_nui_leaf_style(void *opaque, double id, const char *json, size_t len);
extern int oriel_nui_leaf(void *opaque, double id, double style_id, const char *text, size_t len, int is_text);
extern int oriel_nui_frame(void *opaque, double id, double *out5);
extern void oriel_nui_focus(void *opaque, double id);
extern void oriel_nui_scroll_into_view(void *opaque, double id, const char *block, size_t len);
extern void oriel_nui_scroll_to(void *opaque, double id, double y);

#if defined(ORIEL_NATIVE_DOM)
#include "dom_qjs.h"
#endif

typedef struct {
    JSRuntime *rt;
    JSContext *ctx;
    void *opaque;
#if defined(ORIEL_NATIVE_DOM)
    DomCtx *dom; // the native DOM (docs/native-dom.md)
#endif
    // Calls from Zig in progress (eval and jobs nest when a host function
    // calls back into the page).
    int depth;
} oqjs;

// The outermost call from Zig: the stack limit counts from here (the
// runtime was created at another depth, and calls come from many).
static void enter(oqjs *self) {
    if (self->depth++ == 0) JS_UpdateStackTop(self->rt);
}
static void leave(oqjs *self) { self->depth--; }

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

static JSValue h_leaf_style(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_FALSE;
    double id;
    if (JS_ToFloat64(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, argv[1]);
    if (!s) return JS_EXCEPTION;
    int ok = oriel_nui_leaf_style(opaque_of(ctx), id, s, len);
    JS_FreeCString(ctx, s);
    return JS_NewBool(ctx, ok);
}

static JSValue h_leaf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 4) return JS_FALSE;
    double id, style_id;
    if (JS_ToFloat64(ctx, &id, argv[0]) < 0 || JS_ToFloat64(ctx, &style_id, argv[1]) < 0) return JS_EXCEPTION;
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, argv[2]);
    if (!s) return JS_EXCEPTION;
    int is_text = JS_ToBool(ctx, argv[3]);
    int ok = oriel_nui_leaf(opaque_of(ctx), id, style_id, s, len, is_text);
    JS_FreeCString(ctx, s);
    return JS_NewBool(ctx, ok);
}

// A text node's single run changed: straight to the tree and the backend
// (Backend.text), without a JSON round trip.
static JSValue h_text(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_FALSE;
    double id;
    if (JS_ToFloat64(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
    size_t len = 0;
    const char *s = JS_ToCStringLen(ctx, &len, argv[1]);
    if (!s) return JS_EXCEPTION;
    int ok = oriel_nui_text(opaque_of(ctx), id, s, len);
    JS_FreeCString(ctx, s);
    return JS_NewBool(ctx, ok);
}

#if defined(ORIEL_NATIVE_DOM)
// host.stampPlan([n, (text style, box style, transform) x n, order x n]):
// a row plan's id for host.stamp, 0 when not kept (tree.zig).
static JSValue h_stamp_plan(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t len;
    if (argc < 1 || JS_GetLength(ctx, argv[0], &len) < 0) return JS_EXCEPTION;
    if (len <= 0 || len > 1 + 64 * 4) return JS_NewUint32(ctx, 0);
    double v[1 + 64 * 4];
    for (int64_t i = 0; i < len; i++) {
        JSValue x = JS_GetPropertyUint32(ctx, argv[0], (uint32_t)i);
        int bad = JS_ToFloat64(ctx, &v[i], x);
        JS_FreeValue(ctx, x);
        if (bad) return JS_EXCEPTION;
    }
    return JS_NewUint32(ctx, oriel_nui_stamp_plan(opaque_of(ctx), v, (size_t)len));
}
#endif

#if defined(ORIEL_NATIVE_DOM)
// host.stamp(rowId, rowElement, plan): the tree makes the row's leaves from
// the native DOM itself (dom_stamp.zig); false when the row doesn't have
// the plan's shape now.
static JSValue h_stamp(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    double row_id;
    uint32_t plan;
    if (argc < 3 || JS_ToFloat64(ctx, &row_id, argv[0]) || JS_ToUint32(ctx, &plan, argv[2])) return JS_EXCEPTION;
    void *dom = nui_dom_of_ctx(ctx);
    uint32_t row = nui_dom_node_index(argv[1]);
    if (!dom || !row) return JS_FALSE;
    return JS_NewBool(ctx, oriel_nui_stamp(opaque_of(ctx), row_id, dom, row, plan));
}

// host.stampList(listId, listElement, rowStyle, plan, templateRow, keptRows):
// the list's rows but the template and the kept ones (made by the runtime)
// stamped by the tree from the native DOM (dom_stamp.zig); false when a
// row isn't the template again.
static JSValue h_stamp_list(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    double list_id, row_style;
    uint32_t plan;
    int64_t kept_len;
    if (argc < 4 || JS_ToFloat64(ctx, &list_id, argv[0]) || JS_ToFloat64(ctx, &row_style, argv[2]) ||
        JS_ToUint32(ctx, &plan, argv[3])) return JS_EXCEPTION;
    // Without a template row: the list's first; without kept rows: none.
    kept_len = 0;
    if (argc >= 6 && JS_GetLength(ctx, argv[5], &kept_len) < 0) return JS_EXCEPTION;
    void *dom = nui_dom_of_ctx(ctx);
    uint32_t list = nui_dom_node_index(argv[1]), template_row = argc >= 5 ? nui_dom_node_index(argv[4]) : 0;
    if (!dom || !list || kept_len < 0 || kept_len > 64) return JS_FALSE;
    uint32_t kept[64];
    for (int64_t i = 0; i < kept_len; i++) {
        JSValue v = JS_GetPropertyUint32(ctx, argv[5], (uint32_t)i);
        kept[i] = nui_dom_node_index(v);
        JS_FreeValue(ctx, v);
        if (!kept[i]) return JS_FALSE;
    }
    return JS_NewBool(ctx, oriel_nui_stamp_list(opaque_of(ctx), list_id, dom, list, row_style, plan, template_row, kept, (size_t)kept_len));
}
#endif

// host.canvas(id, Float64Array, [strings]): a canvas node's program as
// numbers (canvas.js encodeProgram), read in place: no JSON either way.
static JSValue h_canvas(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    double id;
    if (argc < 3 || JS_ToFloat64(ctx, &id, argv[0])) return JS_EXCEPTION;
    size_t offset = 0, bytes = 0, per = 0;
    JSValue buffer = JS_GetTypedArrayBuffer(ctx, argv[1], &offset, &bytes, &per);
    if (JS_IsException(buffer)) return JS_EXCEPTION;
    size_t size = 0;
    uint8_t *data = JS_GetArrayBuffer(ctx, &size, buffer);
    JS_FreeValue(ctx, buffer);
    if (!data || per != 8 || offset + bytes > size) return JS_ThrowTypeError(ctx, "host.canvas: a Float64Array");
    int64_t count = 0;
    if (JS_GetLength(ctx, argv[2], &count) < 0) return JS_EXCEPTION;
    if (count < 0 || count > 1 << 20) return JS_FALSE;
    const char **strs = count ? js_malloc(ctx, (size_t)count * sizeof *strs) : NULL;
    size_t *lens = count ? js_malloc(ctx, (size_t)count * sizeof *lens) : NULL;
    if (count && (!strs || !lens)) { js_free(ctx, strs); js_free(ctx, lens); return JS_EXCEPTION; }
    int64_t made = 0;
    int ok = 1;
    for (; made < count; made++) {
        JSValue v = JS_GetPropertyUint32(ctx, argv[2], (uint32_t)made);
        strs[made] = JS_ToCStringLen(ctx, &lens[made], v);
        JS_FreeValue(ctx, v);
        if (!strs[made]) { ok = 0; break; }
    }
    // The doubles in place (a Float64Array's storage is 8-byte aligned).
    int r = ok ? oriel_nui_canvas(opaque_of(ctx), id, (const double *)(data + offset), bytes / 8, strs, lens, (size_t)count) : 0;
    for (int64_t i = 0; i < made; i++) JS_FreeCString(ctx, strs[i]);
    js_free(ctx, strs);
    js_free(ctx, lens);
    return ok ? JS_NewBool(ctx, r) : JS_EXCEPTION;
}

// host.warmFonts([[size, weight, italic, mono], ...]): fonts the backend
// loads while idle (at most 64).
static JSValue h_warm_fonts(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t len;
    if (argc < 1 || JS_GetLength(ctx, argv[0], &len) < 0) return JS_EXCEPTION;
    if (len > 64) len = 64;
    double v[64 * 4];
    size_t n = 0;
    for (int64_t i = 0; i < len; i++) {
        JSValue spec = JS_GetPropertyUint32(ctx, argv[0], (uint32_t)i);
        int bad = 0;
        for (uint32_t k = 0; k < 4 && !bad; k++) {
            JSValue x = JS_GetPropertyUint32(ctx, spec, k);
            bad = JS_ToFloat64(ctx, &v[n * 4 + k], x);
            JS_FreeValue(ctx, x);
        }
        JS_FreeValue(ctx, spec);
        if (bad) return JS_EXCEPTION;
        n++;
    }
    oriel_nui_warm_fonts(opaque_of(ctx), v, n);
    return JS_UNDEFINED;
}

// host.fontMetrics(size, mono): the backend's [ascent, descent, lineGap]
// in px for its text font at `size`, or undefined (the runtime estimates).
static JSValue h_font_metrics(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    double size = 16;
    if (argc >= 1 && JS_ToFloat64(ctx, &size, argv[0]) < 0) return JS_EXCEPTION;
    int mono = argc >= 2 ? JS_ToBool(ctx, argv[1]) : 0;
    double out[3];
    if (!oriel_nui_font_metrics(opaque_of(ctx), size, mono, out)) return JS_UNDEFINED;
    JSValue arr = JS_NewArray(ctx);
    for (uint32_t i = 0; i < 3; i++) JS_SetPropertyUint32(ctx, arr, i, JS_NewFloat64(ctx, out[i]));
    return arr;
}

// host.vsync(): __oriel.vsync(interval) at the display's next refresh;
// false when the backend can't (requestAnimationFrame keeps its timers).
static JSValue h_vsync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return JS_NewBool(ctx, oriel_nui_vsync(opaque_of(ctx)));
}

// host.now(): a monotonic clock in ms, sub-millisecond (performance.now).
static JSValue h_now(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
#if defined(_WIN32)
    LARGE_INTEGER t, f;
    QueryPerformanceCounter(&t);
    QueryPerformanceFrequency(&f);
    return JS_NewFloat64(ctx, (double)t.QuadPart * 1e3 / (double)f.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return JS_NewFloat64(ctx, (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6);
#endif
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

// ---- ES modules ---------------------------------------------------------------
// `<script type="module">` and `import()`: module names are asset paths
// ("assets/index-x.js"); `./x`, `../x` resolve against the importing module,
// `/x` and `app://app/x` against the root, a query or fragment is dropped.

static char *nui_join(JSContext *ctx, const char *base, const char *name) {
    const char *n = name;
    if (strncmp(n, "app://app/", 10) == 0) n += 10;
    size_t blen = 0;
    if (n[0] == '/') {
        n++;
    } else if (n[0] == '.') {
        const char *slash = strrchr(base, '/');
        if (slash) blen = (size_t)(slash - base) + 1;
    }
    size_t nlen = strcspn(n, "?#");
    char *out = js_malloc(ctx, blen + nlen + 1);
    if (!out) return NULL;
    memcpy(out, base, blen);
    memcpy(out + blen, n, nlen);
    out[blen + nlen] = 0;
    // Collapse "./" and "dir/../" segments in place.
    char *segs[128];
    int depth = 0;
    char *w = out, *r = out;
    while (*r) {
        char *end = strchr(r, '/');
        size_t len = end ? (size_t)(end - r) : strlen(r);
        if ((len == 1 && r[0] == '.') || len == 0) {
        } else if (len == 2 && r[0] == '.' && r[1] == '.') {
            if (depth > 0) w = segs[--depth];
        } else {
            // Deeper than this, a later ".." would pop the wrong level:
            // refuse the path instead of resolving it to another module.
            if (depth == 128) {
                js_free(ctx, out);
                JS_ThrowReferenceError(ctx, "module path too deep: %s", name);
                return NULL;
            }
            segs[depth++] = w;
            memmove(w, r, len);
            w += len;
            if (end) *w++ = '/';
        }
        if (!end) break;
        r = end + 1;
    }
    *w = 0;
    return out;
}

static char *nui_normalize(JSContext *ctx, const char *base, const char *name, void *opaque) {
    (void)opaque;
    return nui_join(ctx, base, name);
}

// import.meta.resolve(spec): the app:// URL of `spec` from this module.
static JSValue nui_meta_resolve(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *data) {
    (void)this_val; (void)magic;
    if (argc < 1) return JS_UNDEFINED;
    const char *base = JS_ToCString(ctx, data[0]);
    const char *spec = JS_ToCString(ctx, argv[0]);
    JSValue res = JS_UNDEFINED;
    if (base && spec) {
        char *p = nui_join(ctx, base, spec);
        if (p) {
            size_t plen = strlen(p);
            char *url = js_malloc(ctx, plen + 11);
            if (url) {
                memcpy(url, "app://app/", 10);
                memcpy(url + 10, p, plen + 1);
                res = JS_NewString(ctx, url);
                js_free(ctx, url);
            }
            js_free(ctx, p);
        } else {
            res = JS_EXCEPTION; // nui_join threw (too deep, or out of memory)
        }
    }
    if (base) JS_FreeCString(ctx, base);
    if (spec) JS_FreeCString(ctx, spec);
    return res;
}

static int nui_set_meta(JSContext *ctx, JSModuleDef *m, const char *name) {
    JSValue meta = JS_GetImportMeta(ctx, m);
    if (JS_IsException(meta)) return -1;
    size_t nlen = strlen(name);
    char *url = js_malloc(ctx, nlen + 11);
    if (!url) { JS_FreeValue(ctx, meta); return -1; }
    memcpy(url, "app://app/", 10);
    memcpy(url + 10, name, nlen + 1);
    JS_SetPropertyStr(ctx, meta, "url", JS_NewString(ctx, url));
    js_free(ctx, url);
    JSValue base = JS_NewString(ctx, name);
    JS_SetPropertyStr(ctx, meta, "resolve", JS_NewCFunctionData(ctx, nui_meta_resolve, 1, 0, 1, &base));
    JS_FreeValue(ctx, base);
    JS_FreeValue(ctx, meta);
    return 0;
}

// Compile `code` (needs a NUL at code[len]) as module `name` with its
// import.meta set: the module value (for JS_EvalFunction), or an exception.
// Compiled modules as bytecode, for the process (every window's engine is
// its own QuickJS runtime, and each one parsed and compiled the page's
// bundle again: ~16 ms for GhostPen's 239 KB, per window). Keyed by name,
// length and a hash of the source; read back with JS_ReadObject (as the
// runtime itself and qjsc binaries load). UI thread only, as engines are.
typedef struct ModuleCode {
    struct ModuleCode *next;
    char *name;
    size_t len;
    uint64_t hash;
    uint8_t *bytes;
    size_t size;
} ModuleCode;
static ModuleCode *module_codes;
static size_t module_code_bytes;
#define MODULE_CODE_LIMIT ((size_t)32 << 20)

static uint64_t fnv1a(const char *s, size_t len) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) { h ^= (uint8_t)s[i]; h *= 1099511628211ULL; }
    return h;
}

static ModuleCode *module_code_find(const char *name, size_t len, uint64_t hash) {
    for (ModuleCode *m = module_codes; m; m = m->next)
        if (m->len == len && m->hash == hash && !strcmp(m->name, name)) return m;
    return NULL;
}

static void module_code_keep(JSContext *ctx, const char *name, size_t len, uint64_t hash, JSValueConst fn) {
    size_t size = 0;
    uint8_t *buf = JS_WriteObject(ctx, &size, fn, JS_WRITE_OBJ_BYTECODE);
    if (!buf) { JS_FreeValue(ctx, JS_GetException(ctx)); return; }
    ModuleCode *m = NULL;
    if (module_code_bytes + size <= MODULE_CODE_LIMIT && (m = malloc(sizeof *m))) {
        m->bytes = malloc(size);
        m->name = strdup(name);
        if (m->bytes && m->name) {
            memcpy(m->bytes, buf, size);
            m->size = size;
            m->len = len;
            m->hash = hash;
            m->next = module_codes;
            module_codes = m;
            module_code_bytes += size;
        } else {
            free(m->bytes);
            free(m->name);
            free(m);
        }
    }
    js_free(ctx, buf);
}

// Parsed style sheets, for the process: the runtime keeps a sheet's rules
// as JSON by its text (host.sheetKeep) and later windows read them back
// (host.sheetCache) instead of parsing it again (~10 ms for GhostPen's).
typedef struct SheetCode {
    struct SheetCode *next;
    char *css;
    size_t len;
    uint64_t hash;
    char *json;
    size_t json_len;
} SheetCode;
static SheetCode *sheet_codes;
static size_t sheet_code_bytes;
#define SHEET_CODE_LIMIT ((size_t)8 << 20)

static SheetCode *sheet_find(const char *css, size_t len, uint64_t hash) {
    for (SheetCode *m = sheet_codes; m; m = m->next)
        if (m->len == len && m->hash == hash && !memcmp(m->css, css, len)) return m;
    return NULL;
}

static const char *embedded_sheet(JSContext *ctx, JSValueConst path, uint64_t hash, size_t len, size_t *size);

// host.sheetCache(css, path): the rules JSON kept for this text, or the
// one the app was built with for its asset `path` (if it's this text), or
// undefined.
static JSValue h_sheet_cache(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    size_t len;
    const char *css = JS_ToCStringLen(ctx, &len, argv[0]);
    if (!css) return JS_EXCEPTION;
    const uint64_t hash = fnv1a(css, len);
    const SheetCode *m = sheet_find(css, len, hash);
    JS_FreeCString(ctx, css);
    if (m) return JS_NewStringLen(ctx, m->json, m->json_len);
    size_t size = 0;
    const char *json = argc >= 2 && JS_IsString(argv[1]) ? embedded_sheet(ctx, argv[1], hash, len, &size) : NULL;
    return json ? JS_NewStringLen(ctx, json, size) : JS_UNDEFINED;
}

// host.sheetKeep(css, json): keep a sheet's rules for later windows.
static JSValue h_sheet_keep(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_UNDEFINED;
    size_t len, json_len;
    const char *css = JS_ToCStringLen(ctx, &len, argv[0]);
    const char *json = JS_ToCStringLen(ctx, &json_len, argv[1]);
    const uint64_t hash = css ? fnv1a(css, len) : 0;
    if (css && json && !sheet_find(css, len, hash) && sheet_code_bytes + len + json_len <= SHEET_CODE_LIMIT) {
        SheetCode *m = malloc(sizeof *m);
        char *c = malloc(len ? len : 1), *j = malloc(json_len ? json_len : 1);
        if (m && c && j) {
            memcpy(c, css, len);
            memcpy(j, json, json_len);
            *m = (SheetCode){ sheet_codes, c, len, hash, j, json_len };
            sheet_codes = m;
            sheet_code_bytes += len + json_len;
        } else {
            free(m);
            free(c);
            free(j);
        }
    }
    if (css) JS_FreeCString(ctx, css);
    if (json) JS_FreeCString(ctx, json);
    return JS_UNDEFINED;
}

// The module's bytecode compiled with the app (tools/qjs_modules.zig:
// "<name>.qjsbc", "OQJSMOD1", the source's hash and length, the bytecode),
// when it was compiled from this source; else NULL.
static const uint8_t *embedded_module(JSContext *ctx, const char *name, uint64_t hash, size_t len, size_t *size) {
    char path[512];
    int n = snprintf(path, sizeof path, "%s.qjsbc", name);
    if (n <= 0 || (size_t)n >= sizeof path) return NULL;
    const char *data = NULL;
    size_t data_len = 0;
    if (!oriel_nui_asset(opaque_of(ctx), path, (size_t)n, &data, &data_len) || data_len <= 24) return NULL;
    if (memcmp(data, "OQJSMOD1", 8) != 0) return NULL;
    uint64_t h = 0, l = 0;
    for (int i = 7; i >= 0; i--) { h = (h << 8) | (uint8_t)data[8 + i]; l = (l << 8) | (uint8_t)data[16 + i]; }
    if (h != hash || l != (uint64_t)len) return NULL;
    *size = data_len - 24;
    return (const uint8_t *)data + 24;
}

// A sheet's rules parsed with the app (tools/qjs_modules.zig:
// "<path>.sheet", "OQJSSHT1", the sheet's hash and length, the JSON), when
// they were parsed from this text; else NULL.
static const char *embedded_sheet(JSContext *ctx, JSValueConst path_value, uint64_t hash, size_t len, size_t *size) {
    size_t path_len;
    const char *name = JS_ToCStringLen(ctx, &path_len, path_value);
    if (!name) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        return NULL;
    }
    char path[512];
    int n = snprintf(path, sizeof path, "%s.sheet", name);
    JS_FreeCString(ctx, name);
    if (n <= 0 || (size_t)n >= sizeof path) return NULL;
    const char *data = NULL;
    size_t data_len = 0;
    if (!oriel_nui_asset(opaque_of(ctx), path, (size_t)n, &data, &data_len) || data_len <= 24) return NULL;
    if (memcmp(data, "OQJSSHT1", 8) != 0) return NULL;
    uint64_t h = 0, l = 0;
    for (int i = 7; i >= 0; i--) { h = (h << 8) | (uint8_t)data[8 + i]; l = (l << 8) | (uint8_t)data[16 + i]; }
    if (h != hash || l != (uint64_t)len) return NULL;
    *size = data_len - 24;
    return data + 24;
}

static JSValue nui_compile_module(JSContext *ctx, const char *name, const char *code, size_t len) {
    const uint64_t hash = fnv1a(code, len);
    const ModuleCode *kept = module_code_find(name, len, hash);
    size_t embedded_size = 0;
    const uint8_t *embedded = kept ? NULL : embedded_module(ctx, name, hash, len, &embedded_size);
    JSValue fn;
    if (kept) {
        fn = JS_ReadObject(ctx, kept->bytes, kept->size, JS_READ_OBJ_BYTECODE);
    } else if (embedded && !JS_IsException(fn = JS_ReadObject(ctx, embedded, embedded_size, JS_READ_OBJ_BYTECODE))) {
        // Read (else, as when there's none: compiled from the source).
    } else {
        if (embedded) JS_FreeValue(ctx, JS_GetException(ctx));
        fn = JS_Eval(ctx, code, len, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
        if (!JS_IsException(fn)) module_code_keep(ctx, name, len, hash, fn);
    }
    if (JS_IsException(fn)) return fn;
    if (nui_set_meta(ctx, JS_VALUE_GET_PTR(fn), name) < 0) { JS_FreeValue(ctx, fn); return JS_EXCEPTION; }
    return fn;
}

static JSModuleDef *nui_load_module(JSContext *ctx, const char *name, void *opaque) {
    (void)opaque;
    const char *data = NULL;
    size_t len = 0;
    if (!oriel_nui_asset(opaque_of(ctx), name, strlen(name), &data, &len)) {
        JS_ThrowReferenceError(ctx, "module not found: %s", name);
        return NULL;
    }
    // Assets aren't NUL-terminated; JS_Eval needs it.
    char *code = js_malloc(ctx, len + 1);
    if (!code) return NULL;
    memcpy(code, data, len);
    code[len] = 0;
    JSValue fn = nui_compile_module(ctx, name, code, len);
    js_free(ctx, code);
    if (JS_IsException(fn)) return NULL;
    // The loader hands back the definition; the runtime keeps the module.
    JSModuleDef *m = JS_VALUE_GET_PTR(fn);
    JS_FreeValue(ctx, fn);
    return m;
}

// host.evalModule(name, code): run a module script; returns its evaluation
// promise (the caller reports a rejection).
static JSValue h_eval_module(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_UNDEFINED;
    size_t nlen = 0, clen = 0;
    const char *raw = JS_ToCStringLen(ctx, &nlen, argv[0]);
    const char *code = JS_ToCStringLen(ctx, &clen, argv[1]);
    JSValue ret = JS_UNDEFINED;
    if (raw && code) {
        char *name = nui_join(ctx, "", raw);
        if (name) {
            JSValue fn = nui_compile_module(ctx, name, code, clen);
            if (JS_IsException(fn)) {
                report(ctx);
            } else {
                // Links the imports (through the loader) and runs it: a
                // promise for its evaluation (consumes fn).
                ret = JS_EvalFunction(ctx, fn);
                if (JS_IsException(ret)) { report(ctx); ret = JS_UNDEFINED; }
            }
            js_free(ctx, name);
        }
    }
    if (raw) JS_FreeCString(ctx, raw);
    if (code) JS_FreeCString(ctx, code);
    return ret;
}

static void set_fn(JSContext *ctx, JSValue obj, const char *name, JSCFunction *fn, int len) {
    JS_SetPropertyStr(ctx, obj, name, JS_NewCFunction(ctx, fn, name, len));
}

void *oqjs_new(void *opaque, const char *platform_json, const char *label, const char *url) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return NULL;
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { JS_FreeRuntime(rt); return NULL; }
    oqjs *self = js_malloc(ctx, sizeof *self);
    self->rt = rt;
    self->ctx = ctx;
    self->opaque = opaque;
    self->depth = 0;
    JS_SetContextOpaque(ctx, opaque);
    JS_SetMaxStackSize(rt, NUI_MAX_STACK);
    JS_SetModuleLoaderFunc(rt, nui_normalize, nui_load_module, NULL);

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue host = JS_NewObject(ctx);
    set_fn(ctx, host, "log", h_log, 2);
    set_fn(ctx, host, "asset", h_asset, 1);
    set_fn(ctx, host, "invoke", h_invoke, 3);
    set_fn(ctx, host, "timer", h_timer, 2);
    set_fn(ctx, host, "ops", h_ops, 1);
    set_fn(ctx, host, "text", h_text, 2);
    set_fn(ctx, host, "leafStyle", h_leaf_style, 2);
    set_fn(ctx, host, "leaf", h_leaf, 4);
    set_fn(ctx, host, "frame", h_frame, 1);
    set_fn(ctx, host, "now", h_now, 0);
    set_fn(ctx, host, "vsync", h_vsync, 0);
    set_fn(ctx, host, "warmFonts", h_warm_fonts, 1);
    set_fn(ctx, host, "fontMetrics", h_font_metrics, 2);
    set_fn(ctx, host, "canvas", h_canvas, 3);
    set_fn(ctx, host, "sheetCache", h_sheet_cache, 2);
    set_fn(ctx, host, "sheetKeep", h_sheet_keep, 2);
#if defined(ORIEL_NATIVE_DOM)
    // Rows stamped from the native DOM (Android learns of the nodes the
    // tree makes through Backend.leaf).
    set_fn(ctx, host, "stampPlan", h_stamp_plan, 1);
    set_fn(ctx, host, "stamp", h_stamp, 3);
    set_fn(ctx, host, "stampList", h_stamp_list, 6);
#endif
    set_fn(ctx, host, "focus", h_focus, 1);
    set_fn(ctx, host, "scrollIntoView", h_scroll_into_view, 2);
    set_fn(ctx, host, "scrollTo", h_scroll_to, 2);
    set_fn(ctx, host, "evalScript", h_eval_script, 2);
    set_fn(ctx, host, "evalModule", h_eval_module, 2);
    JS_SetPropertyStr(ctx, host, "platform", JS_NewString(ctx, platform_json));
    JS_SetPropertyStr(ctx, host, "label", JS_NewString(ctx, label));
    JS_SetPropertyStr(ctx, host, "url", JS_NewString(ctx, url));
#if defined(ORIEL_NUI_PROF)
    JS_SetPropertyStr(ctx, host, "prof", JS_TRUE);
#endif
#if defined(ORIEL_NATIVE_DOM)
    // The native DOM: its interfaces and __nuiDom as globals, the document
    // as __host.document (runtime-native.js).
    self->dom = nui_dom_install(ctx);
    if (!self->dom) {
        JS_FreeValue(ctx, host);
        JS_FreeValue(ctx, global);
        js_free(ctx, self);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        return NULL;
    }
    JS_SetPropertyStr(ctx, host, "document", nui_dom_document_object(self->dom));
#endif
    JS_SetPropertyStr(ctx, global, "__host", host);
    JS_FreeValue(ctx, global);
    return self;
}

// Run `code` as a global script; 1 if it returned a truthy value, 0 if not,
// -1 on an exception (logged).
int oqjs_eval(void *p, const char *code, size_t len, const char *name) {
    oqjs *self = p;
    enter(self);
    JSValue r = JS_Eval(self->ctx, code, len, name, JS_EVAL_TYPE_GLOBAL);
    leave(self);
    if (JS_IsException(r)) { report(self->ctx); return -1; }
    int truthy = JS_ToBool(self->ctx, r);
    JS_FreeValue(self->ctx, r);
    return truthy > 0 ? 1 : 0;
}

// Run a script compiled to bytecode (JS_WriteObject: tools/qjs_bytecode.c);
// 0, or -1 on an exception (logged) or a bytecode this QuickJS can't read.
int oqjs_eval_bytecode(void *p, const uint8_t *code, size_t len) {
    oqjs *self = p;
    enter(self);
    JSValue fn = JS_ReadObject(self->ctx, code, len, JS_READ_OBJ_BYTECODE);
    JSValue r = JS_IsException(fn) ? fn : JS_EvalFunction(self->ctx, fn); // consumes fn
    leave(self);
    if (JS_IsException(r)) { report(self->ctx); return -1; }
    JS_FreeValue(self->ctx, r);
    return 0;
}

// Run the pending promise jobs (microtasks).
void oqjs_run_jobs(void *p) {
    oqjs *self = p;
    JSContext *job_ctx;
    enter(self);
    for (;;) {
        int r = JS_ExecutePendingJob(self->rt, &job_ctx);
        if (r == 0) break;
        if (r < 0) report(job_ctx);
    }
    leave(self);
}

// A cycle collection now (idle, after a big removal: detached trees the
// native DOM's wrappers hold in cycles go, see dom/store.zig).
void oqjs_run_gc(void *p) {
    oqjs *self = p;
    JS_RunGC(self->rt);
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
#if defined(ORIEL_NATIVE_DOM)
    // Before the context: the store holds values of it.
    nui_dom_uninstall(self->dom);
#endif
    js_free(ctx, self);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
}
