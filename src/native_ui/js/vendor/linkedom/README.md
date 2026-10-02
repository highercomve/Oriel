# Oriel-owned LinkeDOM source

This directory vendors the ESM runtime and CommonJS support files from
[LinkeDOM](https://github.com/WebReflection/linkedom) version **0.18.13**
(npm release, `https://registry.npmjs.org/linkedom/-/linkedom-0.18.13.tgz`). The upstream ISC license is preserved in `LICENSE`, and original
package metadata is recorded in `UPSTREAM_PACKAGE.json`. Upstream CJS builds,
types, and worker bundles are omitted; Oriel imports this ESM source directly.

Oriel changes (upstream trailing whitespace is also normalized):

- Allocate event-listener Maps on the first listener, rather than for every node.
- Read/write simple single-token class names without allocating a DOMTokenList;
  preserve token normalization and an exposed live classList through the general path.
- Initialize ordinary div/span and document-created Text nodes in one function,
  preserving constructor fields and prototypes. Registry matches, customized
  built-ins and upgrades retain constructor behavior. Constructor-layout tests
  must be updated if upstream changes these instance fields.
- Give the private renderer observer connected-node callbacks that avoid mutation
  record allocation. Page-created observers retain the upstream record behavior.
- Use the canvas shim explicitly; Oriel renders canvas through the native bridge.

There are no build-time source patches or imports from `node_modules/linkedom`.
Unmodified parser, selector, and utility dependencies remain npm dependencies,
pinned in the runtime package and lockfile. Any dependency we modify for native
performance must first become owned source in `vendor`, with its license and
upstream provenance preserved.

To refresh upstream, compare against 0.18.13, preserve and review these changes,
and run `npm run build` and `npm test` from `src/native_ui/js`, then the native
renderer checks and row benchmarks. Do not overwrite the fork from npm at build
time.
