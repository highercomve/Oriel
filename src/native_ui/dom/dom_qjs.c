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
#include <strings.h>
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
    uint32_t (*value_atom)(void *ctx, const JSValue *v);
    bool (*tokens)(void *ctx, const JSValue *v, void *sink, bool (*add)(void *sink, uint32_t atom));
    const uint8_t *(*latin1)(void *ctx, const JSValue *v, size_t *len);
    const uint8_t *(*to_utf8)(void *ctx, const JSValue *v, size_t *len);
    void (*free_utf8)(void *ctx, const uint8_t *p);
    const uint8_t *(*atom_latin1)(void *ctx, uint32_t atom, size_t *len);
    const uint8_t *(*atom_utf8)(void *ctx, uint32_t atom, size_t *len);
    void (*mutation)(void *ctx, uint8_t kind, Index target, Index node, uint32_t name);
    int (*ref_count)(void *ctx, const JSValue *v);
    int (*has_state)(void *ctx, const JSValue *v);
} Host;

typedef struct Selector Selector;

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
extern void nui_dom_marks(Dom *d, Index idx, void *ctx, void (*mark)(void *ctx, const JSValue *v));
extern const JSValue *nui_dom_data(Dom *d, Index idx);
extern void nui_dom_set_data(Dom *d, Index idx, const JSValue *v);
extern const JSValue *nui_dom_get_attr(Dom *d, Index idx, uint32_t name);
extern int nui_dom_set_attr(Dom *d, Index idx, uint32_t name, const JSValue *v);
extern bool nui_dom_remove_attr(Dom *d, Index idx, uint32_t name);
extern size_t nui_dom_attr_count(Dom *d, Index idx);
extern uint32_t nui_dom_attr_at(Dom *d, Index idx, size_t i, const JSValue **out);
extern int nui_dom_parse_html(Dom *d, Index root, const uint8_t *bytes, size_t len);
extern Selector *nui_dom_selector(Dom *d, const uint8_t *bytes, size_t len, int *code);
extern bool nui_dom_matches(Dom *d, Index idx, const Selector *s);
extern Index nui_dom_closest(Dom *d, Index idx, const Selector *s);
extern void nui_dom_query(Dom *d, Index root, const Selector *s, void *ctx, bool (*found)(void *ctx, Index idx));
extern Index nui_dom_by_id(Dom *d, Index root, uint32_t id);
extern Index nui_dom_clone(Dom *d, Index idx, bool deep);
extern int nui_dom_serialize(Dom *d, Index idx, bool outer, const uint8_t **out, size_t *len);
extern Index nui_dom_parse_fragment(Dom *d, const uint8_t *bytes, size_t len, int *code);
extern Index nui_dom_child_named(Dom *d, Index parent, uint32_t name);
extern bool nui_dom_foreign(Dom *d, Index idx);
extern void nui_dom_set_foreign(Dom *d, Index idx, bool foreign);
extern void nui_dom_observe(Dom *d, bool on, bool connected_only);
extern void nui_dom_collect(Dom *d);
extern Index nui_dom_create_document(Dom *d);
extern int nui_dom_keep_selector(Dom *d, const uint8_t *bytes, size_t len);
extern bool nui_dom_match_kept(Dom *d, Index idx, uint32_t id);
extern bool nui_dom_alive(Dom *d, Index idx);
extern void nui_dom_set_listens(Dom *d, Index idx);
extern bool nui_dom_class_style_only(Dom *d, Index idx, bool allow_style, const JSValue **cls, const JSValue **style);

enum { K_ELEMENT = 1, K_TEXT = 3, K_COMMENT = 8, K_DOCUMENT = 9, K_FRAGMENT = 11 };
enum { P_NODE, P_CHARDATA, P_TEXT, P_COMMENT, P_ELEMENT, P_HTML, P_FRAGMENT, P_DOCUMENT, P_COUNT };

struct DomCtx {
    JSContext *ctx;
    Dom *dom;
    Host host;
    bool closing;
    JSValue protos[P_COUNT];
    JSValue ctors[P_COUNT];
    JSAtom a_class, a_id, a_html, a_head, a_body, a_title;
    // Prototypes for elements by tag name (an object: tag → prototype), for
    // other tags, and for SVG/MathML elements; set by the JS side.
    JSValue tag_protos, element_proto, foreign_proto;
    // The mutation hook (the JS side's observers), or undefined.
    JSValue hook;
    // Page observers are on (not just the renderer's): records carry the
    // added node's siblings.
    bool page_observing;
    // The mutations a binding's store operations reported, for the hook once
    // the binding is done with the store (page JS never runs inside an
    // operation): REC values per record, wrappers held so removed nodes live.
    JSValue *pending;
    uint32_t pending_head, pending_len, pending_cap;
    bool delivering;
};

static JSClassID node_class_id;

static DomCtx *dc_of(JSContext *ctx) { return JS_GetRuntimeOpaque(JS_GetRuntime(ctx)); }

// --- Host functions for the store -------------------------------------------

static void h_dup(void *c, const JSValue *v) { JS_DupValue((JSContext *)c, *v); }
static void h_free(void *c, const JSValue *v) { JS_FreeValue((JSContext *)c, *v); }
static int h_ref_count(void *c, const JSValue *v) { (void)c; return JS_GetRefCount(*v); }
static int h_has_state(void *c, const JSValue *v);
static void h_dup_atom(void *c, uint32_t a) { JS_DupAtom((JSContext *)c, a); }
static void h_free_atom(void *c, uint32_t a) { JS_FreeAtom((JSContext *)c, a); }
static bool h_new_string(void *c, const uint8_t *b, size_t len, JSValue *out) {
    *out = JS_NewStringLen((JSContext *)c, (const char *)b, len);
    return !JS_IsException(*out);
}
static uint32_t h_new_atom(void *c, const uint8_t *b, size_t len) {
    return JS_NewAtomLen((JSContext *)c, (const char *)b, len);
}
static uint32_t h_value_atom(void *c, const JSValue *v) {
    return JS_ValueToAtom((JSContext *)c, *v);
}
static const uint8_t *h_latin1(void *c, const JSValue *v, size_t *len) {
    (void)c;
    return JS_GetStringLatin1(*v, len);
}
static const uint8_t *h_to_utf8(void *c, const JSValue *v, size_t *len) {
    return (const uint8_t *)JS_ToCStringLen((JSContext *)c, len, *v);
}
static void h_free_utf8(void *c, const uint8_t *p) {
    JS_FreeCString((JSContext *)c, (const char *)p);
}
static const uint8_t *h_atom_latin1(void *c, uint32_t atom, size_t *len) {
    return JS_GetAtomLatin1((JSContext *)c, atom, len);
}
static const uint8_t *h_atom_utf8(void *c, uint32_t atom, size_t *len) {
    JSContext *ctx = c;
    JSValue v = JS_AtomToString(ctx, atom);
    if (JS_IsException(v)) return NULL;
    const char *s = JS_ToCStringLen(ctx, len, v);
    JS_FreeValue(ctx, v);
    return (const uint8_t *)s;
}

// The ASCII-whitespace-separated tokens of a string value, as atoms.
static bool h_tokens(void *c, const JSValue *v, void *sink, bool (*add)(void *, uint32_t)) {
    JSContext *ctx = c;
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, *v);
    if (!s) return false;
    bool ok = true;
    size_t i = 0;
    while (ok && i < len) {
        while (i < len && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '\f')) i++;
        size_t start = i;
        while (i < len && !(s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '\f')) i++;
        if (i > start) {
            JSAtom a = JS_NewAtomLen(ctx, s + start, i - start);
            ok = a != JS_ATOM_NULL && add(sink, a);
        }
    }
    JS_FreeCString(ctx, s);
    return ok;
}

// --- Wrappers ------------------------------------------------------------------

static void node_finalizer(JSRuntime *rt, JSValueConst val) {
    DomCtx *dc = JS_GetRuntimeOpaque(rt);
    Index idx = (Index)(uintptr_t)JS_GetOpaque(val, node_class_id);
    // While the DOM is being freed (or after), the store isn't told.
    if (!dc || dc->closing || !dc->dom || !idx) return;
    nui_dom_wrapper_finalized(dc->dom, idx);
}

// The wrappers this one holds through the store (store.zig `marks`): a
// detached tree's root owns the others, each owned one its root, so the
// cycle collector frees a tree the page dropped.
typedef struct { JSRuntime *rt; JS_MarkFunc *mark_func; } MarkCtx;

static void mark_one(void *ctx, const JSValue *v) {
    MarkCtx *m = ctx;
    JS_MarkValue(m->rt, *v, m->mark_func);
}

static void node_gc_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark_func) {
    DomCtx *dc = JS_GetRuntimeOpaque(rt);
    Index idx = (Index)(uintptr_t)JS_GetOpaque(val, node_class_id);
    if (!dc || dc->closing || !dc->dom || !idx) return;
    MarkCtx m = { rt, mark_func };
    nui_dom_marks(dc->dom, idx, &m, mark_one);
}

static JSClassDef node_class = { "Node", .finalizer = node_finalizer, .gc_mark = node_gc_mark };

// An element's prototype: by tag, else the default (new reference).
static JSValue element_proto(JSContext *ctx, DomCtx *dc, Index idx) {
    if (nui_dom_foreign(dc->dom, idx) && JS_IsObject(dc->foreign_proto)) return JS_DupValue(ctx, dc->foreign_proto);
    if (JS_IsObject(dc->tag_protos)) {
        JSValue p = JS_GetProperty(ctx, dc->tag_protos, nui_dom_name(dc->dom, idx));
        if (JS_IsObject(p)) return p;
        JS_FreeValue(ctx, p);
    }
    return JS_DupValue(ctx, JS_IsObject(dc->element_proto) ? dc->element_proto : dc->protos[P_HTML]);
}

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
    int which = proto_for(dc, idx);
    JSValue obj;
    if (which == P_HTML) {
        JSValue proto = element_proto(ctx, dc, idx);
        obj = JS_NewObjectProtoClass(ctx, proto, node_class_id);
        JS_FreeValue(ctx, proto);
    } else {
        obj = JS_NewObjectProtoClass(ctx, dc->protos[which], node_class_id);
    }
    if (JS_IsException(obj)) return obj;
    // The allocation may have run the cycle collector, whose finalizers can
    // free a detached tree (no record is reused meanwhile): then there's no
    // node any more (__nuiDom.nodeAt's index).
    if (!nui_dom_alive(dc->dom, idx)) { JS_FreeValue(ctx, obj); return JS_NULL; }
    JS_SetOpaque(obj, (void *)(uintptr_t)idx);
    nui_dom_set_wrapper(dc->dom, idx, &obj);
    return obj;
}

// The wrapper for a node just made, which is dropped if that fails.
static JSValue wrap_new(JSContext *ctx, DomCtx *dc, Index idx) {
    JSValue w = wrap(ctx, dc, idx);
    if (JS_IsException(w)) nui_dom_drop_if_unused(dc->dom, idx);
    return w;
}

// Whether a node's wrapper carries state of its own: expandos, a changed
// prototype (against the one wrap() gives its node), not extensible.
static int h_has_state(void *c, const JSValue *v) {
    JSContext *ctx = c;
    DomCtx *dc = dc_of(ctx);
    Index idx = (Index)(uintptr_t)JS_GetOpaque(*v, node_class_id);
    if (!dc || !dc->dom || !idx) return 1;
    int which = proto_for(dc, idx);
    JSValue want = which == P_HTML ? element_proto(ctx, dc, idx) : JS_DupValue(ctx, dc->protos[which]);
    bool state = JS_ObjectHasState(*v, want);
    JS_FreeValue(ctx, want);
    return state;
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

// An attribute name's atom for an element: as given for SVG/MathML
// elements, ASCII-lowercased for HTML ones.
static JSAtom name_atom(JSContext *ctx, JSValueConst v);
static JSAtom attr_atom(JSContext *ctx, DomCtx *dc, Index el, JSValueConst v) {
    return nui_dom_foreign(dc->dom, el) ? JS_ValueToAtom(ctx, v) : name_atom(ctx, v);
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

// The bindings that change the tree: the mutation hook sees what they did
// once they're done with the store (`deliver`).
static JSValue deliver(JSContext *ctx, DomCtx *dc, JSValue ret);
#define MUTATOR(fname)                                                                         \
    static JSValue fname(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { \
        return deliver(ctx, dc_of(ctx), fname##_op(ctx, this_val, argc, argv));               \
    }
#define MUTATOR_SET(fname)                                                     \
    static JSValue fname(JSContext *ctx, JSValueConst this_val, JSValueConst v) { \
        return deliver(ctx, dc_of(ctx), fname##_op(ctx, this_val, v));          \
    }

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

static JSValue node_append_child_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return insert(ctx, dc, self, argv[0], 0);
}
MUTATOR(node_append_child)

static JSValue node_insert_before_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    Index ref = 0;
    if (argc > 1 && !JS_IsNull(argv[1]) && !JS_IsUndefined(argv[1])) {
        ref = arg_node(ctx, argv[1]);
        if (!ref) return JS_EXCEPTION;
    }
    return insert(ctx, dc, self, argv[0], ref);
}
MUTATOR(node_insert_before)

static JSValue node_remove_child_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    Index child = arg_node(ctx, argv[0]);
    if (!child) return JS_EXCEPTION;
    if (nui_dom_parent(dc->dom, child) != self) return throw_code(ctx, -3);
    JSValue ret = JS_DupValue(ctx, argv[0]); // keeps the child alive past the removal
    nui_dom_remove(dc->dom, child);
    return ret;
}
MUTATOR(node_remove_child)

static JSValue node_remove_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    nui_dom_remove(dc->dom, self);
    return JS_UNDEFINED;
}
MUTATOR(node_remove)

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

static JSValue node_append_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return append_args(ctx, dc, self, 0, argc, argv);
}
MUTATOR(node_append)

static JSValue node_prepend_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return append_args(ctx, dc, self, nui_dom_first(dc->dom, self), argc, argv);
}
MUTATOR(node_prepend)

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

static JSValue node_set_text_op(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
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
MUTATOR_SET(node_set_text)

// --- CharacterData (text, comments) ----------------------------------------------

static JSValue data_get(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    const JSValue *d = nui_dom_data(dc->dom, self);
    return d ? JS_DupValue(ctx, *d) : JS_NewString(ctx, "");
}

static JSValue data_set_op(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    JSValue s = JS_ToString(ctx, v);
    if (JS_IsException(s)) return s;
    nui_dom_set_data(dc->dom, self, &s);
    JS_FreeValue(ctx, s);
    return JS_UNDEFINED;
}
MUTATOR_SET(data_set)

// --- Element ----------------------------------------------------------------------

static JSValue el_local_name(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    return JS_AtomToString(ctx, nui_dom_name(dc->dom, self));
}

static JSValue el_tag_name(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    if (nui_dom_foreign(dc->dom, self)) return JS_AtomToString(ctx, nui_dom_name(dc->dom, self));
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
    JSAtom a = attr_atom(ctx, dc, self, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    JSValue r = get_attr_atom(ctx, dc, self, a);
    JS_FreeAtom(ctx, a);
    return r;
}

static JSValue el_has_attribute(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    JSAtom a = attr_atom(ctx, dc, self, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    bool has = nui_dom_get_attr(dc->dom, self, a) != NULL;
    JS_FreeAtom(ctx, a);
    return JS_NewBool(ctx, has);
}

static JSValue el_set_attribute_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    JSAtom a = attr_atom(ctx, dc, self, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    JSValue r = set_attr_atom(ctx, dc, self, a, argc > 1 ? argv[1] : JS_UNDEFINED);
    JS_FreeAtom(ctx, a);
    return r;
}
MUTATOR(el_set_attribute)

static JSValue el_remove_attribute_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    JSAtom a = attr_atom(ctx, dc, self, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    nui_dom_remove_attr(dc->dom, self, a);
    JS_FreeAtom(ctx, a);
    return JS_UNDEFINED;
}
MUTATOR(el_remove_attribute)

static JSValue el_get_class(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    JSValue r = get_attr_atom(ctx, dc, self, dc->a_class);
    return JS_IsNull(r) ? JS_NewString(ctx, "") : r;
}
static JSValue el_set_class_op(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    return set_attr_atom(ctx, dc, self, dc->a_class, v);
}
MUTATOR_SET(el_set_class)
static JSValue el_get_id(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    JSValue r = get_attr_atom(ctx, dc, self, dc->a_id);
    return JS_IsNull(r) ? JS_NewString(ctx, "") : r;
}
static JSValue el_set_id_op(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    return set_attr_atom(ctx, dc, self, dc->a_id, v);
}
MUTATOR_SET(el_set_id)

static JSValue el_set_inner_html_op(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, v);
    if (!s) return JS_EXCEPTION;
    nui_dom_remove_children(dc->dom, self);
    // Into a fragment first: the observers see the top-level nodes inserted,
    // not every node the markup makes.
    int code = 0;
    Index f = nui_dom_parse_fragment(dc->dom, (const uint8_t *)s, len, &code);
    JS_FreeCString(ctx, s);
    if (!f) return throw_code(ctx, code);
    int r = nui_dom_insert(dc->dom, self, f, 0);
    nui_dom_drop_if_unused(dc->dom, f);
    return r ? throw_code(ctx, r) : JS_UNDEFINED;
}
MUTATOR_SET(el_set_inner_html)

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

// --- Selectors ------------------------------------------------------------------------

// The compiled selector for a JS value, or NULL with a SyntaxError (or out
// of memory) pending.
static const Selector *selector_of(JSContext *ctx, DomCtx *dc, JSValueConst v) {
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, v);
    if (!s) return NULL;
    int code = 0;
    const Selector *sel = nui_dom_selector(dc->dom, (const uint8_t *)s, len, &code);
    if (!sel) {
        if (code == -4) JS_ThrowSyntaxError(ctx, "'%s' is not a valid selector", s);
        else JS_ThrowOutOfMemory(ctx);
    }
    JS_FreeCString(ctx, s);
    return sel;
}

static JSValue el_matches(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    const Selector *sel = selector_of(ctx, dc, argv[0]);
    if (!sel) return JS_EXCEPTION;
    return JS_NewBool(ctx, nui_dom_matches(dc->dom, self, sel));
}

static JSValue el_closest(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    const Selector *sel = selector_of(ctx, dc, argv[0]);
    if (!sel) return JS_EXCEPTION;
    return wrap(ctx, dc, nui_dom_closest(dc->dom, self, sel));
}

typedef struct { JSContext *ctx; DomCtx *dc; JSValue arr; uint32_t n; Index first; bool all; bool failed; } QueryCtx;

static bool query_found(void *p, Index idx) {
    QueryCtx *q = p;
    if (!q->all) { q->first = idx; return false; }
    JSValue w = wrap(q->ctx, q->dc, idx);
    if (JS_IsException(w)) { q->failed = true; return false; }
    JS_SetPropertyUint32(q->ctx, q->arr, q->n++, w);
    return true;
}

static JSValue query(JSContext *ctx, DomCtx *dc, Index root, JSValueConst sel_v, bool all) {
    const Selector *sel = selector_of(ctx, dc, sel_v);
    if (!sel) return JS_EXCEPTION;
    QueryCtx q = { ctx, dc, JS_UNDEFINED, 0, 0, all, false };
    if (all) {
        q.arr = JS_NewArray(ctx);
        if (JS_IsException(q.arr)) return q.arr;
    }
    nui_dom_query(dc->dom, root, sel, &q, query_found);
    if (q.failed) { JS_FreeValue(ctx, q.arr); return JS_EXCEPTION; }
    return all ? q.arr : wrap(ctx, dc, q.first);
}

static JSValue node_query_one(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return query(ctx, dc, self, argv[0], false);
}

static JSValue node_query_all(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    return query(ctx, dc, self, argv[0], true);
}

static JSValue doc_get_by_id(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    JSAtom a = JS_ValueToAtom(ctx, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    Index n = nui_dom_by_id(dc->dom, self, a);
    JS_FreeAtom(ctx, a);
    return wrap(ctx, dc, n);
}

// --- Markup, cloning --------------------------------------------------------------------

static JSValue serialize(JSContext *ctx, DomCtx *dc, Index idx, bool outer) {
    const uint8_t *p;
    size_t len;
    if (nui_dom_serialize(dc->dom, idx, outer, &p, &len)) return JS_ThrowOutOfMemory(ctx);
    return JS_NewStringLen(ctx, (const char *)p, len);
}

static JSValue el_get_inner_html(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    return serialize(ctx, dc, self, false);
}

static JSValue el_get_outer_html(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    return serialize(ctx, dc, self, true);
}

// Markup as a new fragment (0 with an exception pending).
static Index fragment_of(JSContext *ctx, DomCtx *dc, JSValueConst v) {
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, v);
    if (!s) return 0;
    int code = 0;
    Index f = nui_dom_parse_fragment(dc->dom, (const uint8_t *)s, len, &code);
    JS_FreeCString(ctx, s);
    if (!f) throw_code(ctx, code);
    return f;
}

static JSValue el_set_outer_html_op(JSContext *ctx, JSValueConst this_val, JSValueConst v) {
    THIS_NODE();
    Index parent = nui_dom_parent(dc->dom, self);
    if (!parent) return JS_UNDEFINED; // a detached element: nothing to replace (as browsers, minus the error)
    Index f = fragment_of(ctx, dc, v);
    if (!f) return JS_EXCEPTION;
    int r = nui_dom_insert(dc->dom, parent, f, self);
    nui_dom_drop_if_unused(dc->dom, f);
    if (r) return throw_code(ctx, r);
    nui_dom_remove(dc->dom, self);
    return JS_UNDEFINED;
}
MUTATOR_SET(el_set_outer_html)

// insertAdjacent{HTML,Element,Text}: where the node goes for a position.
static int adjacent(JSContext *ctx, DomCtx *dc, Index self, JSValueConst where, Index *parent, Index *ref) {
    const char *w = JS_ToCString(ctx, where);
    if (!w) return -1;
    int ok = 0;
    if (!strcasecmp(w, "beforebegin")) { *parent = nui_dom_parent(dc->dom, self); *ref = self; }
    else if (!strcasecmp(w, "afterbegin")) { *parent = self; *ref = nui_dom_first(dc->dom, self); }
    else if (!strcasecmp(w, "beforeend")) { *parent = self; *ref = 0; }
    else if (!strcasecmp(w, "afterend")) { *parent = nui_dom_parent(dc->dom, self); *ref = nui_dom_next(dc->dom, self); }
    else ok = -1;
    if (ok < 0) JS_ThrowSyntaxError(ctx, "'%s' is not a valid position", w);
    JS_FreeCString(ctx, w);
    if (!ok && !*parent) { JS_ThrowTypeError(ctx, "NoModificationAllowedError: the element has no parent"); ok = -1; }
    return ok;
}

static JSValue el_insert_adjacent_html_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    Index parent = 0, ref = 0;
    if (adjacent(ctx, dc, self, argv[0], &parent, &ref)) return JS_EXCEPTION;
    Index f = fragment_of(ctx, dc, argc > 1 ? argv[1] : JS_UNDEFINED);
    if (!f) return JS_EXCEPTION;
    int r = nui_dom_insert(dc->dom, parent, f, ref);
    nui_dom_drop_if_unused(dc->dom, f);
    return r ? throw_code(ctx, r) : JS_UNDEFINED;
}
MUTATOR(el_insert_adjacent_html)

static JSValue el_insert_adjacent_element_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    Index parent = 0, ref = 0;
    if (adjacent(ctx, dc, self, argv[0], &parent, &ref)) return JS_EXCEPTION;
    return insert(ctx, dc, parent, argc > 1 ? argv[1] : JS_UNDEFINED, ref);
}
MUTATOR(el_insert_adjacent_element)

static JSValue el_insert_adjacent_text_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    Index parent = 0, ref = 0;
    if (adjacent(ctx, dc, self, argv[0], &parent, &ref)) return JS_EXCEPTION;
    Index t = text_from(ctx, dc, argc > 1 ? argv[1] : JS_UNDEFINED);
    if (!t) return JS_EXCEPTION;
    int r = nui_dom_insert(dc->dom, parent, t, ref);
    if (r) { nui_dom_drop_if_unused(dc->dom, t); return throw_code(ctx, r); }
    return JS_UNDEFINED;
}
MUTATOR(el_insert_adjacent_text)

static JSValue node_clone_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    bool deep = argc > 0 && JS_ToBool(ctx, argv[0]);
    Index c = nui_dom_clone(dc->dom, self, deep);
    return c ? wrap_new(ctx, dc, c) : JS_ThrowOutOfMemory(ctx);
}
MUTATOR(node_clone)

// --- Document ---------------------------------------------------------------------

static JSValue doc_document_element(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    return wrap(ctx, dc, nui_dom_child_named(dc->dom, self, 0));
}

static JSValue doc_head(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    Index html = nui_dom_child_named(dc->dom, self, dc->a_html);
    return wrap(ctx, dc, html ? nui_dom_child_named(dc->dom, html, dc->a_head) : 0);
}

static JSValue doc_body(JSContext *ctx, JSValueConst this_val) {
    THIS_NODE();
    Index html = nui_dom_child_named(dc->dom, self, dc->a_html);
    return wrap(ctx, dc, html ? nui_dom_child_named(dc->dom, html, dc->a_body) : 0);
}

// Parses a whole page (index.html) into the document: its markup as the
// document's children (<html> with <head> and <body>).
static JSValue doc_write_page_op(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    THIS_NODE();
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, argv[0]);
    if (!s) return JS_EXCEPTION;
    nui_dom_remove_children(dc->dom, self);
    int r = nui_dom_parse_html(dc->dom, self, (const uint8_t *)s, len);
    JS_FreeCString(ctx, s);
    return r ? throw_code(ctx, r) : JS_UNDEFINED;
}
MUTATOR(doc_write_page)

static JSValue doc_create_element(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    JSAtom a = name_atom(ctx, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    Index n = nui_dom_create_element(dc->dom, a);
    JS_FreeAtom(ctx, a);
    if (!n) return JS_ThrowOutOfMemory(ctx);
    return wrap_new(ctx, dc, n);
}

static JSValue doc_create_text(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index n = text_from(ctx, dc, argc > 0 ? argv[0] : JS_UNDEFINED);
    return n ? wrap_new(ctx, dc, n) : JS_EXCEPTION;
}

static JSValue doc_create_comment(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    JSValue s = JS_ToString(ctx, argc > 0 ? argv[0] : JS_UNDEFINED);
    if (JS_IsException(s)) return s;
    Index n = nui_dom_create_data(dc->dom, K_COMMENT, &s);
    JS_FreeValue(ctx, s);
    return n ? wrap_new(ctx, dc, n) : JS_ThrowOutOfMemory(ctx);
}

static JSValue doc_create_fragment(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index n = nui_dom_create_fragment(dc->dom);
    return n ? wrap_new(ctx, dc, n) : JS_ThrowOutOfMemory(ctx);
}

// --- The JS side's hooks (__nuiDom) -------------------------------------------------------

// [kind, target, node, name, previousSibling, nextSibling]
enum { REC = 6 };

static void free_values(JSContext *ctx, JSValue *v, int n) {
    for (int i = 0; i < n; i++) JS_FreeValue(ctx, v[i]);
}

// Called by the store inside an operation: only records the mutation (the
// wrappers it makes run no page code). `deliver` calls the hook.
static void h_mutation(void *c, uint8_t kind, Index target, Index node, uint32_t name) {
    JSContext *ctx = c;
    DomCtx *dc = dc_of(ctx);
    if (!dc || dc->closing || !JS_IsFunction(ctx, dc->hook)) return;
    JSValue rec[REC];
    rec[0] = JS_NewInt32(ctx, kind);
    rec[1] = wrap(ctx, dc, target);
    rec[2] = node ? wrap(ctx, dc, node) : JS_NULL;
    rec[3] = name ? JS_AtomToString(ctx, name) : JS_UNDEFINED;
    // The siblings as they are now (later mutations in the operation move them).
    bool siblings = kind == 1 && node && dc->page_observing;
    rec[4] = siblings ? wrap(ctx, dc, nui_dom_prev(dc->dom, node)) : JS_NULL;
    rec[5] = siblings ? wrap(ctx, dc, nui_dom_next(dc->dom, node)) : JS_NULL;
    bool ok = true;
    for (int i = 0; i < REC; i++) ok = ok && !JS_IsException(rec[i]);
    if (ok && dc->pending_len + REC > dc->pending_cap) {
        uint32_t cap = dc->pending_cap ? dc->pending_cap * 2 : 16 * REC;
        JSValue *p = js_realloc(ctx, dc->pending, cap * sizeof *p);
        if (p) { dc->pending = p; dc->pending_cap = cap; } else ok = false;
    }
    if (!ok) {
        // Out of memory: the record is lost (as an observer's own error).
        JS_FreeValue(ctx, JS_GetException(ctx));
        free_values(ctx, rec, REC);
        return;
    }
    memcpy(dc->pending + dc->pending_len, rec, sizeof rec);
    dc->pending_len += REC;
}

// Calls the hook with the recorded mutations, in order: at the end of a
// binding that changed the tree, once the store is consistent. The hook's
// page code may change the tree again; its records are delivered by this
// same loop. Returns `ret` (an exception pending for it is kept).
static JSValue deliver(JSContext *ctx, DomCtx *dc, JSValue ret) {
    if (!dc || dc->delivering || dc->pending_head == dc->pending_len) return ret;
    JSValue err = JS_IsException(ret) ? JS_GetException(ctx) : JS_UNDEFINED;
    dc->delivering = true;
    while (dc->pending_head < dc->pending_len) {
        JSValue rec[REC];
        memcpy(rec, dc->pending + dc->pending_head, sizeof rec);
        dc->pending_head += REC;
        if (!dc->closing && JS_IsFunction(ctx, dc->hook)) {
            JSValue hook = JS_DupValue(ctx, dc->hook);
            JSValue r = JS_Call(ctx, hook, JS_UNDEFINED, REC, rec);
            JS_FreeValue(ctx, hook);
            if (JS_IsException(r)) {
                // An observer's error doesn't stop the mutation (as in browsers):
                // it's reported when the page's console runs.
                JSValue e = JS_GetException(ctx);
                JS_FreeValue(ctx, e);
            }
            JS_FreeValue(ctx, r);
        }
        free_values(ctx, rec, REC);
    }
    dc->pending_head = dc->pending_len = 0;
    dc->delivering = false;
    if (JS_IsException(ret)) JS_Throw(ctx, err);
    return ret;
}

// __nuiDom.setProto(tag, proto): "" for other tags, "#foreign" for SVG/MathML.
static JSValue nd_set_proto(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    const char *tag = JS_ToCString(ctx, argv[0]);
    if (!tag) return JS_EXCEPTION;
    if (!*tag) { JS_FreeValue(ctx, dc->element_proto); dc->element_proto = JS_DupValue(ctx, argv[1]); }
    else if (!strcmp(tag, "#foreign")) { JS_FreeValue(ctx, dc->foreign_proto); dc->foreign_proto = JS_DupValue(ctx, argv[1]); }
    else {
        if (!JS_IsObject(dc->tag_protos)) dc->tag_protos = JS_NewObjectProto(ctx, JS_NULL);
        JS_SetPropertyStr(ctx, dc->tag_protos, tag, JS_DupValue(ctx, argv[1]));
    }
    JS_FreeCString(ctx, tag);
    return JS_UNDEFINED;
}

// __nuiDom.observe(hook | null, connectedOnly)
static JSValue nd_observe(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    JS_FreeValue(ctx, dc->hook);
    dc->hook = JS_IsFunction(ctx, argv[0]) ? JS_DupValue(ctx, argv[0]) : JS_UNDEFINED;
    bool connected_only = argc > 1 ? JS_ToBool(ctx, argv[1]) : true;
    dc->page_observing = !connected_only;
    nui_dom_observe(dc->dom, JS_IsFunction(ctx, dc->hook), connected_only);
    return JS_UNDEFINED;
}

// __nuiDom.collect(): frees detached trees nothing holds (only where no DOM
// operation is under way: the engine's render).
// __nuiDom.internal(map): marks the runtime's own WeakMap/WeakSet (keyed by
// nodes) so its entries don't keep a node's wrapper from being pruned (a
// page's weak references do); returns it.
static JSValue nd_internal(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    if (argc < 1) return JS_UNDEFINED;
    JS_SetMapInternal(argv[0]);
    return JS_DupValue(ctx, argv[0]);
}

static JSValue nd_collect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    nui_dom_collect(dc_of(ctx)->dom);
    return JS_UNDEFINED;
}

static JSValue nd_keep_selector(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, argv[0]);
    if (!s) return JS_EXCEPTION;
    int id = nui_dom_keep_selector(dc->dom, (const uint8_t *)s, len);
    JSValue r = id >= 0 ? JS_NewInt32(ctx, id) : id == -4 ? JS_ThrowSyntaxError(ctx, "'%s' is not a valid selector", s) : JS_ThrowOutOfMemory(ctx);
    JS_FreeCString(ctx, s);
    return r;
}

static JSValue nd_match_kept(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index idx = (Index)(uintptr_t)JS_GetOpaque(argv[0], node_class_id);
    uint32_t id;
    if (!idx || JS_ToUint32(ctx, &id, argv[1])) return JS_FALSE;
    return JS_NewBool(ctx, nui_dom_match_kept(dc->dom, idx, id));
}

// __nuiDom.classStyle(el, allowStyle): null when the element has other
// attributes, else [class or undefined, style or undefined].
static JSValue nd_class_style(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index idx = arg_node(ctx, argv[0]);
    if (!idx) return JS_EXCEPTION;
    const JSValue *cls, *style;
    if (!nui_dom_class_style_only(dc->dom, idx, argc > 1 && JS_ToBool(ctx, argv[1]), &cls, &style)) return JS_NULL;
    JSValue arr = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, arr, 0, cls ? JS_DupValue(ctx, *cls) : JS_UNDEFINED);
    JS_SetPropertyUint32(ctx, arr, 1, style ? JS_DupValue(ctx, *style) : JS_UNDEFINED);
    return arr;
}

// __nuiDom.attrs(el): [name, value, name, value…] in order.
static JSValue nd_attrs(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index idx = arg_node(ctx, argv[0]);
    if (!idx) return JS_EXCEPTION;
    JSValue arr = JS_NewArray(ctx);
    size_t n = nui_dom_attr_count(dc->dom, idx);
    for (size_t i = 0; i < n; i++) {
        const JSValue *v;
        uint32_t name = nui_dom_attr_at(dc->dom, idx, i, &v);
        JS_SetPropertyUint32(ctx, arr, (uint32_t)(2 * i), JS_AtomToString(ctx, name));
        JS_SetPropertyUint32(ctx, arr, (uint32_t)(2 * i + 1), JS_DupValue(ctx, *v));
    }
    return arr;
}

static JSValue nd_create_document(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index d = nui_dom_create_document(dc->dom);
    return d ? wrap_new(ctx, dc, d) : JS_ThrowOutOfMemory(ctx);
}

static JSValue nd_set_foreign(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index idx = arg_node(ctx, argv[0]);
    if (!idx) return JS_EXCEPTION;
    // Only before the page has seen it (its prototype is chosen then).
    nui_dom_set_foreign(dc->dom, idx, JS_ToBool(ctx, argv[1]));
    return JS_UNDEFINED;
}

// __nuiDom.createElement(tag, foreign): an element with its prototype
// chosen after its namespace (createElementNS).
static JSValue nd_create_element(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    bool foreign = argc > 1 && JS_ToBool(ctx, argv[1]);
    JSAtom a = foreign ? JS_ValueToAtom(ctx, argv[0]) : name_atom(ctx, argv[0]);
    if (a == JS_ATOM_NULL) return JS_EXCEPTION;
    Index n = nui_dom_create_element(dc->dom, a);
    JS_FreeAtom(ctx, a);
    if (!n) return JS_ThrowOutOfMemory(ctx);
    nui_dom_set_foreign(dc->dom, n, foreign);
    return wrap_new(ctx, dc, n);
}

// __nuiDom.index(node): its store index (the renderer's node ids, which
// the tree can stamp from the DOM itself); 0 for no node.
static JSValue nd_index(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    return JS_NewUint32(ctx, (Index)(uintptr_t)JS_GetOpaque(argv[0], node_class_id));
}

// __nuiDom.listens(node): the page listens for clicks on it.
static JSValue nd_listens(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index idx = (Index)(uintptr_t)JS_GetOpaque(argv[0], node_class_id);
    if (idx) nui_dom_set_listens(dc->dom, idx);
    return JS_UNDEFINED;
}

// __nuiDom.nodeAt(index): the node there now, or null.
static JSValue nd_node_at(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    uint32_t idx;
    if (JS_ToUint32(ctx, &idx, argv[0]) || !nui_dom_alive(dc->dom, idx)) return JS_NULL;
    return wrap(ctx, dc, idx);
}

static JSValue nd_is_foreign(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    DomCtx *dc = dc_of(ctx);
    Index idx = (Index)(uintptr_t)JS_GetOpaque(argv[0], node_class_id);
    return JS_NewBool(ctx, idx && nui_dom_foreign(dc->dom, idx));
}

static const JSCFunctionListEntry nui_dom_funcs[] = {
    JS_CFUNC_DEF("setProto", 2, nd_set_proto),
    JS_CFUNC_DEF("observe", 2, nd_observe),
    JS_CFUNC_DEF("collect", 0, nd_collect),
    JS_CFUNC_DEF("internal", 1, nd_internal),
    JS_CFUNC_DEF("keepSelector", 1, nd_keep_selector),
    JS_CFUNC_DEF("matchKept", 2, nd_match_kept),
    JS_CFUNC_DEF("classStyle", 2, nd_class_style),
    JS_CFUNC_DEF("attrs", 1, nd_attrs),
    JS_CFUNC_DEF("createDocument", 0, nd_create_document),
    JS_CFUNC_DEF("createElement", 2, nd_create_element),
    JS_CFUNC_DEF("setForeign", 2, nd_set_foreign),
    JS_CFUNC_DEF("isForeign", 1, nd_is_foreign),
    JS_CFUNC_DEF("index", 1, nd_index),
    JS_CFUNC_DEF("nodeAt", 1, nd_node_at),
    JS_CFUNC_DEF("listens", 1, nd_listens),
};

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
    JS_CFUNC_DEF("cloneNode", 0, node_clone),
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
    JS_CGETSET_DEF("innerHTML", el_get_inner_html, el_set_inner_html),
    JS_CGETSET_DEF("outerHTML", el_get_outer_html, el_set_outer_html),
    JS_CFUNC_DEF("insertAdjacentHTML", 2, el_insert_adjacent_html),
    JS_CFUNC_DEF("insertAdjacentElement", 2, el_insert_adjacent_element),
    JS_CFUNC_DEF("insertAdjacentText", 2, el_insert_adjacent_text),
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
    JS_CFUNC_DEF("matches", 1, el_matches),
    JS_CFUNC_DEF("closest", 1, el_closest),
    JS_CFUNC_DEF("querySelector", 1, node_query_one),
    JS_CFUNC_DEF("querySelectorAll", 1, node_query_all),
};

static const JSCFunctionListEntry fragment_funcs[] = {
    JS_CFUNC_DEF("querySelector", 1, node_query_one),
    JS_CFUNC_DEF("querySelectorAll", 1, node_query_all),
    JS_CFUNC_DEF("getElementById", 1, doc_get_by_id),
    JS_CFUNC_DEF("append", 0, node_append),
    JS_CFUNC_DEF("prepend", 0, node_prepend),
    JS_CGETSET_DEF("children", el_children, NULL),
    JS_CGETSET_DEF("firstElementChild", el_first_element, NULL),
};

static const JSCFunctionListEntry document_funcs[] = {
    JS_CGETSET_DEF("documentElement", doc_document_element, NULL),
    JS_CGETSET_DEF("head", doc_head, NULL),
    JS_CGETSET_DEF("body", doc_body, NULL),
    JS_CFUNC_DEF("__writePage", 1, doc_write_page),
    JS_CFUNC_DEF("querySelector", 1, node_query_one),
    JS_CFUNC_DEF("querySelectorAll", 1, node_query_all),
    JS_CFUNC_DEF("getElementById", 1, doc_get_by_id),
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
    dc->host = (Host){ ctx, h_dup, h_free, h_dup_atom, h_free_atom, h_new_string, h_new_atom, h_value_atom, h_tokens,
                       h_latin1, h_to_utf8, h_free_utf8, h_atom_latin1, h_atom_utf8, h_mutation, h_ref_count, h_has_state };
    dc->tag_protos = dc->element_proto = dc->foreign_proto = dc->hook = JS_UNDEFINED;
    dc->dom = nui_dom_new(&dc->host);
    if (!dc->dom) { js_free(ctx, dc); return NULL; }
    JS_SetRuntimeOpaque(rt, dc);
    dc->a_class = JS_NewAtom(ctx, "class");
    dc->a_id = JS_NewAtom(ctx, "id");
    dc->a_html = JS_NewAtom(ctx, "html");
    dc->a_head = JS_NewAtom(ctx, "head");
    dc->a_body = JS_NewAtom(ctx, "body");
    dc->a_title = JS_NewAtom(ctx, "title");
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
    JSValue nd = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, nd, nui_dom_funcs, COUNT(nui_dom_funcs));
    JS_SetPropertyStr(ctx, global, "__nuiDom", nd);
    JS_FreeValue(ctx, global);
    return dc;
}

JSValue nui_dom_document_object(DomCtx *dc) {
    return wrap(dc->ctx, dc, nui_dom_document(dc->dom));
}

void nui_dom_uninstall(DomCtx *dc) {
    JSContext *ctx = dc->ctx;
    dc->closing = true;
    if (dc->dom) nui_dom_observe(dc->dom, false, true);
    if (dc->pending) {
        free_values(ctx, dc->pending + dc->pending_head, (int)(dc->pending_len - dc->pending_head));
        js_free(ctx, dc->pending);
    }
    dc->pending = NULL;
    dc->pending_head = dc->pending_len = dc->pending_cap = 0;
    JS_FreeValue(ctx, dc->hook);
    JS_FreeValue(ctx, dc->tag_protos);
    JS_FreeValue(ctx, dc->element_proto);
    JS_FreeValue(ctx, dc->foreign_proto);
    dc->hook = dc->tag_protos = dc->element_proto = dc->foreign_proto = JS_UNDEFINED;
    if (dc->dom) nui_dom_free(dc->dom); // drops its wrapper references (finalizers see `closing`)
    dc->dom = NULL;
    for (int i = 0; i < P_COUNT; i++) {
        JS_FreeValue(ctx, dc->protos[i]);
        JS_FreeValue(ctx, dc->ctors[i]);
    }
    JS_FreeAtom(ctx, dc->a_class);
    JS_FreeAtom(ctx, dc->a_id);
    JS_FreeAtom(ctx, dc->a_html);
    JS_FreeAtom(ctx, dc->a_head);
    JS_FreeAtom(ctx, dc->a_body);
    JS_FreeAtom(ctx, dc->a_title);
    // Wrappers freed later (with the context) find no DOM.
    JS_SetRuntimeOpaque(JS_GetRuntime(ctx), NULL);
    js_free(ctx, dc);
}

// For host.stamp (qjs_shim.c): the context's DOM, and a value's node index
// (0 when it isn't a node).
void *nui_dom_of_ctx(JSContext *ctx) {
    DomCtx *dc = dc_of(ctx);
    return dc ? dc->dom : NULL;
}

uint32_t nui_dom_node_index(JSValueConst v) {
    return (Index)(uintptr_t)JS_GetOpaque(v, node_class_id);
}
