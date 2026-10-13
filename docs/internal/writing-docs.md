# Writing Oriel's docs

The docs have one source: the site's pages, `site/content/docs/<page>.smd`
(SuperMD, built by zine). `docs/<page>.md`, `docs/README.md` and the site's
sidebar are generated from them and from `site/docs-index.json`:

```sh
node tools/docs/gen-md.mjs          # after editing a page or the index
node tools/docs/gen-md.mjs --check  # CI: fails when docs/ is out of date
```

Only `docs/internal/` (this kind of note) and `docs/design/` (design
records) are written by hand.

## One page per feature

A feature is something an app uses: a module (`oriel.tray`), a build
option family (`.permissions`), a mechanism (commands, platform hooks), a
tool (the CLI). Each has exactly one page, and everything about it is on that
page; other pages link to it rather than explain it again. A page's sections,
in this order (headings as written, so readers find the same thing in the
same place everywhere):

1. **Lead** (front matter `.description`, one sentence) and a short opening:
   what the feature is for, when to use it and when to use something else.
2. **`# Availability`**: a table of the platforms (Linux, Windows, macOS,
   Android, iOS) with what works on each, the build flag or `AppOptions`
   field that turns it on, and the permissions it needs.
3. **`# Quick start`**: the smallest complete working use: `build.zig`,
   Zig, and the page's JavaScript when the page can use it.
4. **`# How it works`**: the architecture. A diagram first (Mermaid, see
   below), then the flow in prose: which thread runs what, what crosses the
   bridge, where state lives, which source files implement it
   (`src/modules/tray/linux.zig`), what each platform uses underneath.
5. **`# Examples`**: real tasks, each a short heading and complete code.
   Point at the example app or app that uses it (`examples/showcase`,
   GhostPantry) when one does.
6. **`# Reference`**: everything. Every `AppOptions` field, every public Zig
   declaration, every page API and event, with types, defaults, errors,
   limits, threading, and platform differences. If it's public and not here,
   the page is incomplete.
7. **`# Troubleshooting`** (when there is something to say): symptoms and
   fixes, the log lines to look for.
8. **`# Related`**: links to the pages it builds on or is confused with.

Guides (getting started, the tutorial) and overviews (concepts, modules)
don't follow this template; every feature page does.

## One way per feature

Oriel keeps one API per feature. A page documents that one way only. When a
release removes or renames something, the page gets at most a short
**Migrating from 0.x** note under Reference saying what replaced it; the old
form isn't documented anywhere else (the CHANGELOG has the history).

## Diagrams

Mermaid, in the page, so it stays text and is reviewed with the code:

````
>[]($block.attrs("mermaid"))
```
flowchart LR
  Page -->|invoke| Bridge --> Zig
```
````

The site shows it as an image rendered ahead of time, readable on a phone
(tap to enlarge): after adding or changing a diagram, run

```sh
(cd tools/docs && npm install)   # once: mermaid-cli, uses the system's Chrome
node tools/docs/diagrams.mjs     # renders what changed into site/assets/diagrams/
```

and commit the SVGs, `manifest.json` and `zine.ziggy` with the page (CI
runs `node tools/docs/diagrams.mjs --check`). `gen-md.mjs` turns the block
into a ```` ```mermaid ```` block, which GitHub draws. Prefer `flowchart` and `sequenceDiagram`; keep a diagram to
what the prose then explains, and label arrows with what crosses them.

## SuperMD the generator understands

- Headings: `# [Text]($heading.id('anchor'))` (the page title is the h1;
  `#` in the file is a section).
- Links: `[t]($link.page('docs/x'))`, with `.ref('anchor')`;
  `[t]($link.ref('anchor'))` on the same page; plain URLs.
- Images: `[]($image.siteAsset('screenshots/x.png').alt('...'))`.
- Raw HTML: a ```` ```=html ```` block.

Anything else stops the generator with the line it can't convert.

## Style

Plain, direct sentences; say what happens, not what is "powerful". Code
blocks are complete enough to paste. Platform names: Linux, Windows, macOS,
Android, iOS. Name build options as they're written (`.android.hooks`,
`-Dwhisper`).
