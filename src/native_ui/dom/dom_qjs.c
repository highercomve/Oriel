// The native DOM's QuickJS bindings (docs/native-dom.md): JavaScript
// objects for the nodes of the Zig document store (store.zig, capi.zig).
//
// A wrapper is one object of class "Node" per node, made when the page first
// sees the node; its opaque value is the node's store index (no allocation
// per wrapper). Prototypes per interface (Node, CharacterData, Text,
// Comment, Element, HTMLElement, DocumentFragment, Document) give
// `instanceof` and the methods. Strings stay QuickJS strings: the store
// keeps the values the page gives and hands them back.
//
// One DOM per runtime (each window has its own runtime): the runtime's
// opaque pointer is the DomCtx.

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "quickjs.h"
#include "dom_qjs.h"

typedef uint32_t Index;
typedef struct Dom Dom;

// capi.zig's Host (an extern struct of pointers, in this order).
typedef struct {
    void *ctx;
    void (*dup)(void *ctx, const JSValue *v);
    void (*free)(void *ctx, const JSValue *v);
    void (*dup_atom)(void *ctx, uint32_t a);
    void (*free_atom)(void *ctx, uint32_t a);
    bool (*new_string)(void *ctx, const uint8_t *bytes, size_t len, JSValue *out);
    uint32_t (*new_atom)(void *ctx, const uint8_t *bytes, size_t len);
} Host;

extern Dom *nui_dom_new(const Host *host);
extern void nui_dom_free(Dom *d);
extern Index nui_dom_document(Dom *d);
extern Index nui_dom_create_element(Dom *d, uint32_t name);
extern Index nui_dom_create_data(Dom *d, uint8_t kind, const JSValue *data);
extern Index nui_dom_create_fragment(Dom *d);
extern void nui_dom_drop_if_unused(Dom *d, Index idx);
extern uint8_t nui_dom_kind(Dom *d, Index idx);
extern uint32_t nui_dom_name(Dom *d, Index idx);
extern Index nui_dom_parent(Dom *d, Index idx);
extern Index nui_dom_first(Dom *d, Index idx);
extern Index nui_dom_last(Dom *d, Index idx);
extern Index nui_dom_next(Dom *d, Index idx);
extern Index nui_dom_prev(Dom *d, Index idx);
extern bool nui_dom_connected(Dom *d, Index idx);
extern int nui_dom_insert(Dom *d, Index parent, Index child, Index ref);
extern void nui_dom_remove(Dom *d, Index idx);
extern void nui_dom_remove_children(Dom *d, Index idx);
extern const JSValue *nui_dom_wrapper(Dom *d, Index idx);
extern void nui_dom_set_wrapper(Dom *d, Index idx, const JSValue *w);
extern void nui_dom_wrapper_finalized(Dom *d, Index idx);
extern const JSValue *nui_dom_data(Dom *d, Index idx);
extern void nui_dom_set_data(Dom *d, Index idx, const JSValue *v);
extern const JSValue *nui_dom_get_attr(Dom *d, Index idx, uint32_t name);
extern int nui_dom_set_attr(Dom *d, Index idx, uint32_t name, const JSValue *v);
extern bool nui_dom_remove_attr(Dom *d, Index idx, uint32_t name);
extern size_t nui_dom_attr_count(Dom *d, Index idx);
extern uint32_t nui_dom_attr_at(Dom *d, Index idx, size_t i, const JSValue **out);
extern int nui_dom_parse_html(Dom *d, Index root, const uint8_t *bytes, size_t len);

enum { K_ELEMENT = 1, K_TEXT = 3, K_COMMENT = 8, K_DOCUMENT = 9, K_FRAGMENT = 11 };
enum { P_NODE, P_CHARDATA, P_TEXT, P_COMMENT, P_ELEMENT, P_HTML, P_FRAGMENT, P_DOCUMENT, P_COUNT };

struct DomCtx {
    JSContext *ctx;
    Dom *dom;
    Host host;
    bool closing;
    JSValue protos[P_COUNT];
    JSValue ctors[P_COUNT];
    JSAtom a_class, a_id;
};

static JSClassID node_class_id;

static DomCtx *dc_of(JSContext *ctx) { return JS_GetRuntimeOpaque(JS_GetRuntime(ctx)); }

// --- Host functions for the store -------------------------------------------

static void h_dup(void *c, const JSValue *v) { JS_DupValue((JSContext *)c, *v); }
static void h_free(void *c, const JSValue *v) { JS_FreeValue((JSContext *)c, *v); }
static void h_dup_atom(void *c, uint32_t a) { JS_DupAtom((JSContext *)c, a); }
static void h_free_atom(void *c, uint32_t a) { JS_FreeAtom((JSContext *)c, a); }
static bool h_new_string(void *c, const uint8_t *b, size_t len, JSValue *out) {
    *out = JS_NewStringLen((JSContext *)c, (const char *)b, len);
    return !JS_IsException(*out);
}
static uint32_t h_new_atom(void *c, const uint8_t *b, size_t len) {
    return JS_NewAtomLen((JSContext *)c, (const char *)b, len);
}

// --- Wrappers ------------------------------------------------------------------

static void node_finalizer(JSRuntime *rt, JSValueConst val) {
    DomCtx *dc = JS_GetRuntimeOpaque(rt);
    Index idx = (Index)(uintptr_t)JS_GetOpaque(val, node_class_id);
    // While the DOM is being freed (or after), the store isn't told.
    if (!dc || dc->closing || !dc->dom || !idx) return;
    nui_dom_wrapper_finalized(dc->dom, idx);
}

static JSClassDef node_class = { "Node", .finalizer = node_finalizer };

static int proto_for(DomCtx *dc, Index idx) {
    switch (nui_dom_kind(dc->dom, idx)) {
    case K_ELEMENT: return P_HTML;
    case K_TEXT: return P_TEXT;
    case K_COMMENT: return P_COMMENT;
    case K_FRAGMENT: return P_FRAGMENT;
    case K_DOCUMENT: return P_DOCUMENT;
    default: return P_NODE;
    }
}

// The wrapper for a node (a new reference), or null for no node.
static JSValue wrap(JSContext *ctx, DomCtx *dc, Index idx) {
    if (!idx) return JS_NULL;
    const JSValue *w = nui_dom_wrapper(dc->dom, idx);
    if (w) return JS_DupValue(ctx, *w);
    JSValue obj = JS_NewObjectProtoClass(ctx, dc->protos[proto_for(dc, idx)], node_class_id);
    if (JS_IsException(obj)) return obj;
    JS_SetOpaque(obj, (void *)(uintptr_t)idx);
    nui_dom_set_wrapper(dc->dom, idx, &obj);
    return obj;
}

// `this`'s node, or 0 (a TypeError is pending) when it isn't one.
static Index this_node(JSContext *ctx, JSValueConst this_val) {
    Index idx = (Index)(uintptr_t)JS_GetOpaque(this_val, node_class_id);
    if (!idx) JS_ThrowTypeError(ctx, "Illegal invocation");
    return idx;
}

static Index arg_node(JSContext *ctx, JSValueConst v) {
    Index idx = (Index)(uintptr_t)JS_GetOpaque(v, node_class_id);
    if (!idx) JS_ThrowTypeError(ctx, "parameter is not of type 'Node'");
    return idx;
}

static JSValue throw_code(JSContext *ctx, int code) {
    switch (code) {
    case -1: return JS_ThrowOutOfMemory(ctx);
    case -2: return JS_ThrowTypeError(ctx, "HierarchyRequestError: the new child can't be inserted there");
    default: return JS_ThrowTypeError(ctx, "NotFoundError: the node is not a child of this node");
    }
}

// A name atom from a JS value, ASCII-lowercased (HTML names).
static JSAtom name_atom(JSContext *ctx, JSValueConst v) {
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, v);
    if (!s) return JS_ATOM_NULL;
    char buf[64], *b = len < sizeof(buf) ? buf : js_malloc(ctx, len + 1);
    JSAtom a = JS_ATOM_NULL;
    if (b) {
        for (size_t i = 0; i < len; i++) b[i] = (s[i] >= 'A' && s[i] <= 'Z') ? s[i] + 32 : s[i];
        a = JS_NewAtomLen(ctx, b, len);
        if (b != buf) js_free(ctx, b);
    }
    JS_FreeCString(ctx, s);
    return a;
}

// --- Node ----------------------------------------------------------------------

#define THIS_NODE()                                   \
    DomCtx *dc = dc_of(ctx);                          \
    Index self = this_node(ctx, this_val);            \
    if (!self) return JS_EXCEPTION

static JSValue node_get_type(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    return JS_NewInt32(ctx, nui_dom_kind(dc->dom, self));
}

#define LINK_GETTER(fname, fn)                                       \
    static JSValue fname(JSContext *ctx, JSValueConst this_val) {    \
        THIS_NODE();                                                 \
        return wrap(ctx, dc, fn(dc->dom, self));                     \
    }
LINK_GETTER(node_get_parent, nui_dom_parent)
LINK_GETTER(node_get_first, nui_dom_first)
LINK_GETTER(node_get_last, nui_dom_last)
LINK_GETTER(node_get_next, nui_dom_next)
LINK_GETTER(node_get_prev, nui_dom_prev)

static JSValue node_get_parent_element(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    Index p = nui_dom_parent(dc->dom, self);
    return (p && nui_dom_kind(dc->dom, p) == K_ELEMENT) ? wrap(ctx, dc, p) : JS_NULL;
}

static JSValue node_get_connected(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    return JS_NewBool(ctx, nui_dom_connected(dc->dom, self));
}

static JSValue node_has_children(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return JS_NewBool(ctx, nui_dom_first(dc->dom, self) != 0);
}

// childNodes: an array of the children (a snapshot).
static JSValue node_get_child_nodes(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    JSValue arr = JS_NewArray(ctx);
    uint32_t i = 0;
    for (Index c = nui_dom_first(dc->dom, self); c; c = nui_dom_next(dc->dom, c)) {
        JSValue w = wrap(ctx, dc, c);
        if (JS_IsException(w)) { JS_FreeValue(ctx, arr); return w; }
        JS_SetPropertyUint32(ctx, arr, i++, w);
    }
    return arr;
}

static JSValue insert(JSContext *ctx, DomCtx *dc, Index parent, JSValueConst child_v, Index ref) {
    Index child = arg_node(ctx, child_v);
    if (!child) return JS_EXCEPTION;
    int r = nui_dom_insert(dc->dom, parent, child, ref);
    if (r) return throw_code(ctx, r);
    return JS_DupValue(ctx, child_v);
}

static JSValue node_append_child(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return insert(ctx, dc, self, argv[0], 0);
}

static JSValue node_insert_before(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    Index ref = 0;
    if (argc > 1 && !JS_IsNull(argv[1]) && !JS_IsUndefined(argv[1])) {
        ref = arg_node(ctx, argv[1]);
        if (!ref) return JS_EXCEPTION;
    }
    return insert(ctx, dc, self, argv[0], ref);
}

static JSValue node_remove_child(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    Index child = arg_node(ctx, argv[0]);
    if (!child) return JS_EXCEPTION;
    if (nui_dom_parent(dc->dom, child) != self) return throw_code(ctx, -3);
    JSValue ret = JS_DupValue(ctx, argv[0]); // keeps the child alive past the removal
    nui_dom_remove(dc->dom, child);
    return ret;
}

static JSValue node_remove(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    nui_dom_remove(dc->dom, self);
    return JS_UNDEFINED;
}

static JSValue node_contains(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    if (argc < 1 || JS_IsNull(argv[0])) return JS_FALSE;
    Index n = arg_node(ctx, argv[0]);
    if (!n) return JS_EXCEPTION;
    for (; n; n = nui_dom_parent(dc->dom, n)) if (n == self) return JS_TRUE;
    return JS_FALSE;
}

// A string argument (or anything) as a new text node.
static Index text_from(JSContext *ctx, DomCtx *dc, JSValueConst v) {
    JSValue s = JS_ToString(ctx, v);
    if (JS_IsException(s)) return 0;
    Index t = nui_dom_create_data(dc->dom, K_TEXT, &s);
    JS_FreeValue(ctx, s);
    if (!t) JS_ThrowOutOfMemory(ctx);
    return t;
}

// append(...nodes or strings) / prepend
static JSValue append_args(JSContext *ctx, DomCtx *dc, Index parent, Index ref, int argc, JSValueConst *argv) {
    for (int i = 0; i < argc; i++) {
        Index n = (Index)(uintptr_t)JS_GetOpaque(argv[i], node_class_id);
        bool made = false;
        if (!n) {
            n = text_from(ctx, dc, argv[i]);
            if (!n) return JS_EXCEPTION;
            made = true;
        }
        int r = nui_dom_insert(dc->dom, parent, n, ref);
        if (r) {
            if (made) nui_dom_drop_if_unused(dc->dom, n);
            return throw_code(ctx, r);
        }
    }
    return JS_UNDEFINED;
}

static JSValue node_append(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return append_args(ctx, dc, self, 0, argc, argv);
}

static JSValue node_prepend(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return append_args(ctx, dc, self, nui_dom_first(dc->dom, self), argc, argv);
}

// textContent: the descendants' text, concatenated (text and comment nodes:
// their data; the document: null).
static JSValue node_get_text(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    uint8_t k = nui_dom_kind(dc->dom, self);
    if (k == K_TEXT || k == K_COMMENT) {
        const JSValue *d = nui_dom_data(dc->dom, self);
        return d ? JS_DupValue(ctx, *d) : JS_NewString(ctx, "");
    }
    if (k == K_DOCUMENT) return JS_NULL;
    JSValue acc = JS_NewString(ctx, "");
    Index n = nui_dom_first(dc->dom, self);
    while (n) {
        if (nui_dom_kind(dc->dom, n) == K_TEXT) {
            const JSValue *d = nui_dom_data(dc->dom, n);
            if (d) {
                acc = JS_ConcatStrings(ctx, acc, JS_DupValue(ctx, *d));
                if (JS_IsException(acc)) return acc;
            }
        }
        // Next in document order, within self.
        Index f = nui_dom_first(dc->dom, n);
        if (f) { n = f; continue; }
        while (n != self && !nui_dom_next(dc->dom, n)) n = nui_dom_parent(dc->dom, n);
        n = n == self ? 0 : nui_dom_next(dc->dom, n);
    }
    return acc;
}

static JSValue node_set_text(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    uint8_t k = nui_dom_kind(dc->dom, self);
    if (k == K_TEXT || k == K_COMMENT) {
        JSValue s = JS_IsNull(v) ? JS_NewString(ctx, "") : JS_ToString(ctx, v);
        if (JS_IsException(s)) return s;
        nui_dom_set_data(dc->dom, self, &s);
        JS_FreeValue(ctx, s);
        return JS_UNDEFINED;
    }
    if (k == K_DOCUMENT) return JS_UNDEFINED;
    nui_dom_remove_children(dc->dom, self);
    if (JS_IsNull(v) || JS_IsUndefined(v)) return JS_UNDEFINED;
    JSValue s = JS_ToString(ctx, v);
    if (JS_IsException(s)) return s;
    bool empty = JS_GetStringLength(s) == 0;
    if (!empty) {
        Index t = nui_dom_create_data(dc->dom, K_TEXT, &s);
        if (!t) { JS_FreeValue(ctx, s); return JS_ThrowOutOfMemory(ctx); }
        int r = nui_dom_insert(dc->dom, self, t, 0);
        if (r) { nui_dom_drop_if_unused(dc->dom, t); JS_FreeValue(ctx, s); return throw_code(ctx, r); }
    }
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}

// --- CharacterData (text, comments) ----------------------------------------------

static JSValue data_get(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    const JSValue *d = nui_dom_data(dc->dom, self);
    return d ? JS_DupValue(ctx, *d) : JS_NewString(ctx, "");
}

static JSValue data_set(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    JSValue s = JS_ToString(ctx, v);
    if (JS_IsException(s)) return s;
    nui_dom_set_data(dc->dom, self, &s);
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}

// --- Element ----------------------------------------------------------------------

static JSValue el_local_name(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    return JS_AtomToString(ctx, nui_dom_name(dc->dom, self));
}

static JSValue el_tag_name(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    size_t len;
    JSValue name = JS_AtomToString(ctx, nui_dom_name(dc->dom, self));
    const char *s = JS_ToCStringLen(ctx, &len, name);
    JS_FreeValue(ctx, name);
    if (!s) return JS_EXCEPTION;
    char buf[64], *b = len < sizeof(buf) ? buf : js_malloc(ctx, len + 1);
    JSValue ret = JS_EXCEPTION;
    if (b) {
        for (size_t i = 0; i < len; i++) b[i] = (s[i] >= 'a' && s[i] <= 'z') ? s[i] - 32 : s[i];
        ret = JS_NewStringLen(ctx, b, len);
        if (b != buf) js_free(ctx, b);
    }
    JS_FreeCString(ctx, s);
    return ret;
}

static JSValue get_attr_atom(JSContext *ctx, DomCtx *dc, Index self, JSAtom name) {
    const JSValue *v = nui_dom_get_attr(dc->dom, self, name);
    return v ? JS_DupValue(ctx, *v) : JS_NULL;
}

static JSValue set_attr_atom(JSContext *ctx, DomCtx *dc, Index self, JSAtom name, JSValueConst v) {
    JSValue s = JS_ToString(ctx, v);
    if (JS_IsException(s)) return s;
    int r = nui_dom_set_attr(dc->dom, self, name, &s);
    JS_FreeValue(ctx, s);
    return r ? throw_code(ctx, r) : JS_UNDEFINED;
}

static JSValue el_get_attribute(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    JSAtom a = name_atom(ctx, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    JSValue r = get_attr_atom(ctx, dc, self, a);
    JS_FreeAtom(ctx, a);
    return r;
}

static JSValue el_has_attribute(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    JSAtom a = name_atom(ctx, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    bool has = nui_dom_get_attr(dc->dom, self, a) != NULL;
    JS_FreeAtom(ctx, a);
    return JS_NewBool(ctx, has);
}

static JSValue el_set_attribute(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    JSAtom a = name_atom(ctx, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    JSValue r = set_attr_atom(ctx, dc, self, a, argc > 1 ? argv[1] : JS_UNDEFINED);
    JS_FreeAtom(ctx, a);
    return r;
}

static JSValue el_remove_attribute(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    JSAtom a = name_atom(ctx, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    nui_dom_remove_attr(dc->dom, self, a);
    JS_FreeAtom(ctx, a);
    return JS_UNDEFINED;
}

static JSValue el_get_class(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    JSValue r = get_attr_atom(ctx, dc, self, dc->a_class);
    return JS_IsNull(r) ? JS_NewString(ctx, "") : r;
}
static JSValue el_set_class(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    return set_attr_atom(ctx, dc, self, dc->a_class, v);
}
static JSValue el_get_id(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    JSValue r = get_attr_atom(ctx, dc, self, dc->a_id);
    return JS_IsNull(r) ? JS_NewString(ctx, "") : r;
}
static JSValue el_set_id(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    return set_attr_atom(ctx, dc, self, dc->a_id, v);
}

static JSValue el_set_inner_html(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, v);
    if (!s) return JS_EXCEPTION;
    nui_dom_remove_children(dc->dom, self);
    int r = nui_dom_parse_html(dc->dom, self, (const uint8_t *)s, len);
    JS_FreeCString(ctx, s);
    return r ? throw_code(ctx, r) : JS_UNDEFINED;
}

#define ELEM_WALK(fname, start, step)                                             \
    static JSValue fname(JSContext *ctx, JSValueConst this_val) {                 \
        THIS_NODE();                                                              \
        for (Index n = start(dc->dom, self); n; n = step(dc->dom, n))             \
            if (nui_dom_kind(dc->dom, n) == K_ELEMENT) return wrap(ctx, dc, n);   \
        return JS_NULL;                                                           \
    }
ELEM_WALK(el_first_element, nui_dom_first, nui_dom_next)
ELEM_WALK(el_last_element, nui_dom_last, nui_dom_prev)
ELEM_WALK(el_next_element, nui_dom_next, nui_dom_next)
ELEM_WALK(el_prev_element, nui_dom_prev, nui_dom_prev)

static JSValue el_children(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    JSValue arr = JS_NewArray(ctx);
    uint32_t i = 0;
    for (Index c = nui_dom_first(dc->dom, self); c; c = nui_dom_next(dc->dom, c)) {
        if (nui_dom_kind(dc->dom, c) != K_ELEMENT) continue;
        JSValue w = wrap(ctx, dc, c);
        if (JS_IsException(w)) { JS_FreeValue(ctx, arr); return w; }
        JS_SetPropertyUint32(ctx, arr, i++, w);
    }
    return arr;
}

// --- Document ---------------------------------------------------------------------

static JSValue doc_create_element(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    JSAtom a = name_atom(ctx, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    Index n = nui_dom_create_element(dc->dom, a);
    JS_FreeAtom(ctx, a);
    if (!n) return JS_ThrowOutOfMemory(ctx);
    return wrap(ctx, dc, n);
}

static JSValue doc_create_text(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index n = text_from(ctx, dc, argc > 0 ? argv[0] : JS_UNDEFINED);
    return n ? wrap(ctx, dc, n) : JS_EXCEPTION;
}

static JSValue doc_create_comment(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    JSValue s = JS_ToString(ctx, argc > 0 ? argv[0] : JS_UNDEFINED);
    if (JS_IsException(s)) return s;
    Index n = nui_dom_create_data(dc->dom, K_COMMENT, &s);
    JS_FreeValue(ctx, s);
    return n ? wrap(ctx, dc, n) : JS_ThrowOutOfMemory(ctx);
}

static JSValue doc_create_fragment(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index n = nui_dom_create_fragment(dc->dom);
    return n ? wrap(ctx, dc, n) : JS_ThrowOutOfMemory(ctx);
}

// --- Setup ----------------------------------------------------------------------------

static const JSCFunctionListEntry node_funcs[] = {
    JS_CGETSET_DEF("nodeType", node_get_type, NULL),
    JS_CGETSET_DEF("parentNode", node_get_parent, NULL),
    JS_CGETSET_DEF("parentElement", node_get_parent_element, NULL),
    JS_CGETSET_DEF("firstChild", node_get_first, NULL),
    JS_CGETSET_DEF("lastChild", node_get_last, NULL),
    JS_CGETSET_DEF("nextSibling", node_get_next, NULL),
    JS_CGETSET_DEF("previousSibling", node_get_prev, NULL),
    JS_CGETSET_DEF("childNodes", node_get_child_nodes, NULL),
    JS_CGETSET_DEF("isConnected", node_get_connected, NULL),
    JS_CGETSET_DEF("textContent", node_get_text, node_set_text),
    JS_CFUNC_DEF("hasChildNodes", 0, node_has_children),
    JS_CFUNC_DEF("appendChild", 1, node_append_child),
    JS_CFUNC_DEF("insertBefore", 2, node_insert_before),
    JS_CFUNC_DEF("removeChild", 1, node_remove_child),
    JS_CFUNC_DEF("contains", 1, node_contains),
};

static const JSCFunctionListEntry chardata_funcs[] = {
    JS_CGETSET_DEF("data", data_get, data_set),
    JS_CGETSET_DEF("nodeValue", data_get, data_set),
    JS_CFUNC_DEF("remove", 0, node_remove),
};

static const JSCFunctionListEntry element_funcs[] = {
    JS_CGETSET_DEF("localName", el_local_name, NULL),
    JS_CGETSET_DEF("tagName", el_tag_name, NULL),
    JS_CGETSET_DEF("nodeName", el_tag_name, NULL),
    JS_CGETSET_DEF("className", el_get_class, el_set_class),
    JS_CGETSET_DEF("id", el_get_id, el_set_id),
    JS_CGETSET_DEF("innerHTML", NULL, el_set_inner_html),
    JS_CGETSET_DEF("children", el_children, NULL),
    JS_CGETSET_DEF("firstElementChild", el_first_element, NULL),
    JS_CGETSET_DEF("lastElementChild", el_last_element, NULL),
    JS_CGETSET_DEF("nextElementSibling", el_next_element, NULL),
    JS_CGETSET_DEF("previousElementSibling", el_prev_element, NULL),
    JS_CFUNC_DEF("getAttribute", 1, el_get_attribute),
    JS_CFUNC_DEF("setAttribute", 2, el_set_attribute),
    JS_CFUNC_DEF("hasAttribute", 1, el_has_attribute),
    JS_CFUNC_DEF("removeAttribute", 1, el_remove_attribute),
    JS_CFUNC_DEF("append", 0, node_append),
    JS_CFUNC_DEF("prepend", 0, node_prepend),
    JS_CFUNC_DEF("remove", 0, node_remove),
};

static const JSCFunctionListEntry fragment_funcs[] = {
    JS_CFUNC_DEF("append", 0, node_append),
    JS_CFUNC_DEF("prepend", 0, node_prepend),
    JS_CGETSET_DEF("children", el_children, NULL),
    JS_CGETSET_DEF("firstElementChild", el_first_element, NULL),
};

static const JSCFunctionListEntry document_funcs[] = {
    JS_CFUNC_DEF("createElement", 1, doc_create_element),
    JS_CFUNC_DEF("createTextNode", 1, doc_create_text),
    JS_CFUNC_DEF("createComment", 1, doc_create_comment),
    JS_CFUNC_DEF("createDocumentFragment", 0, doc_create_fragment),
    JS_CFUNC_DEF("append", 0, node_append),
    JS_CGETSET_DEF("children", el_children, NULL),
    JS_CGETSET_DEF("firstElementChild", el_first_element, NULL),
};

// A prototype object inheriting `parent` with `funcs`, and a constructor
// `name` for instanceof (not callable from the page: `new Element()` throws).
static JSValue illegal_ctor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) {
    return JS_ThrowTypeError(ctx, "Illegal constructor");
}

static int make_proto(JSContext *ctx, DomCtx *dc, int which, int parent, const char *name,
                      const JSCFunctionListEntry *funcs, int n) {
    JSValue proto = parent < 0 ? JS_NewObject(ctx) : JS_NewObjectProto(ctx, dc->protos[parent]);
    if (JS_IsException(proto)) return -1;
    if (funcs && JS_SetPropertyFunctionList(ctx, proto, funcs, n) < 0) { JS_FreeValue(ctx, proto); return -1; }
    JSValue ctor = JS_NewCFunction2(ctx, illegal_ctor, name, 0, JS_CFUNC_constructor, 0);
    if (JS_IsException(ctor)) { JS_FreeValue(ctx, proto); return -1; }
    JS_SetConstructor(ctx, ctor, proto);
    dc->protos[which] = proto;
    dc->ctors[which] = ctor;
    return 0;
}

DomCtx *nui_dom_install(JSContext *ctx) {
    JSRuntime *rt = JS_GetRuntime(ctx);
    if (!node_class_id) JS_NewClassID(rt, &node_class_id);
    if (!JS_IsRegisteredClass(rt, node_class_id) && JS_NewClass(rt, node_class_id, &node_class) < 0) return NULL;
    DomCtx *dc = js_mallocz(ctx, sizeof(*dc));
    if (!dc) return NULL;
    dc->ctx = ctx;
    for (int i = 0; i < P_COUNT; i++) dc->protos[i] = dc->ctors[i] = JS_UNDEFINED;
    dc->host = (Host){ ctx, h_dup, h_free, h_dup_atom, h_free_atom, h_new_string, h_new_atom };
    dc->dom = nui_dom_new(&dc->host);
    if (!dc->dom) { js_free(ctx, dc); return NULL; }
    JS_SetRuntimeOpaque(rt, dc);
    dc->a_class = JS_NewAtom(ctx, "class");
    dc->a_id = JS_NewAtom(ctx, "id");
#define COUNT(a) (int)(sizeof(a) / sizeof(a[0]))
    if (make_proto(ctx, dc, P_NODE, -1, "Node", node_funcs, COUNT(node_funcs)) ||
        make_proto(ctx, dc, P_CHARDATA, P_NODE, "CharacterData", chardata_funcs, COUNT(chardata_funcs)) ||
        make_proto(ctx, dc, P_TEXT, P_CHARDATA, "Text", NULL, 0) ||
        make_proto(ctx, dc, P_COMMENT, P_CHARDATA, "Comment", NULL, 0) ||
        make_proto(ctx, dc, P_ELEMENT, P_NODE, "Element", element_funcs, COUNT(element_funcs)) ||
        make_proto(ctx, dc, P_HTML, P_ELEMENT, "HTMLElement", NULL, 0) ||
        make_proto(ctx, dc, P_FRAGMENT, P_NODE, "DocumentFragment", fragment_funcs, COUNT(fragment_funcs)) ||
        make_proto(ctx, dc, P_DOCUMENT, P_NODE, "Document", document_funcs, COUNT(document_funcs))) {
        nui_dom_uninstall(dc);
        return NULL;
    }
    // Globals: the interfaces, for instanceof.
    JSValue global = JS_GetGlobalObject(ctx);
    static const char *names[P_COUNT] = { "Node", "CharacterData", "Text", "Comment", "Element", "HTMLElement", "DocumentFragment", "Document" };
    for (int i = 0; i < P_COUNT; i++) JS_SetPropertyStr(ctx, global, names[i], JS_DupValue(ctx, dc->ctors[i]));
    JS_FreeValue(ctx, global);
    return dc;
}

JSValue nui_dom_document_object(DomCtx *dc) {
    return wrap(dc->ctx, dc, nui_dom_document(dc->dom));
}

void nui_dom_uninstall(DomCtx *dc) {
    JSContext *ctx = dc->ctx;
    dc->closing = true;
    if (dc->dom) nui_dom_free(dc->dom); // drops its wrapper references (finalizers see `closing`)
    dc->dom = NULL;
    for (int i = 0; i < P_COUNT; i++) {
        JS_FreeValue(ctx, dc->protos[i]);
        JS_FreeValue(ctx, dc->ctors[i]);
    }
    JS_FreeAtom(ctx, dc->a_class);
    JS_FreeAtom(ctx, dc->a_id);
    // Wrappers freed later (with the context) find no DOM.
    JS_SetRuntimeOpaque(JS_GetRuntime(ctx), NULL);
    js_free(ctx, dc);
}
