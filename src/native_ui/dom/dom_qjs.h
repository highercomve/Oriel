// The native DOM's QuickJS bindings (dom_qjs.c, docs/native-dom.md).
#pragma once
#include "quickjs.h"

typedef struct DomCtx DomCtx;

// Installs the DOM in a context (one per runtime): the store, the
// interfaces (Node, Element… as globals). NULL on failure.
DomCtx *nui_dom_install(JSContext *ctx);
// The document's wrapper (a new reference).
JSValue nui_dom_document_object(DomCtx *dc);
// Frees the DOM (before the context and runtime are freed).
void nui_dom_uninstall(DomCtx *dc);
