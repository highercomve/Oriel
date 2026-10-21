#!/usr/bin/env node
// The docs have one source: the site's pages (site/content/docs/*.smd,
// SuperMD for zine). This writes their GitHub-readable copies into docs/
// (docs/<page>.md and the docs/README.md index), so the two can't drift.
//
//   node tools/docs/gen-md.mjs           write docs/
//   node tools/docs/gen-md.mjs --check   exit 1 when docs/ is out of date (CI)
//
// What it converts (the SuperMD the pages use):
//   front matter                  -> "# Title" and the description
//   # [Text]($heading.id('x'))    -> "## Text" (site h1 is the page title)
//   [t]($link.page('docs/x'))     -> [t](x.md), .ref('a') -> x.md#a
//   [t]($link.ref('a'))           -> [t](#a)
//   []($image.siteAsset('p').alt('t')) -> ![t](../site/assets/p)
//   >[]($block.attrs("mermaid")) + a fenced block -> ```mermaid
//   ```=html blocks                -> kept as raw HTML
// Pages under docs/ that aren't generated (contributor notes, design
// records) live in docs/internal/ and docs/design/, never at the top.

import { readFileSync, writeFileSync, readdirSync, existsSync, unlinkSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const src = join(root, "site", "content", "docs");
const out = join(root, "docs");
const check = process.argv.includes("--check");
const marker = "<!-- Generated from site/content/docs/";

// The sidebar's sections, in order (site/layouts/docs.shtml lists the same).
const index = JSON.parse(readFileSync(join(src, "..", "..", "docs-index.json"), "utf8"));

function frontMatter(text, file) {
  const m = /^---\n([\s\S]*?)\n---\n/.exec(text);
  if (!m) throw new Error(`${file}: no front matter`);
  const field = (name) => {
    const f = new RegExp(`^\\.${name}\\s*=\\s*"((?:[^"\\\\]|\\\\.)*)"`, "m").exec(m[1]);
    return f ? f[1].replace(/\\"/g, '"') : "";
  };
  return { title: field("title"), description: field("description"), body: text.slice(m[0].length) };
}

function link(target) {
  // target: the inside of $link.page('...')... or $link.ref('...')
  let m = /^\$link\.page\('([^']*)'\)(?:\.ref\('([^']*)'\))?$/.exec(target);
  if (m) {
    const page = m[1] === "" ? "../README.md" : m[1].startsWith("docs/") ? `${m[1].slice(5) || "README"}.md` : `../site/content/${m[1]}.smd`;
    return m[2] ? `${page}#${m[2]}` : page;
  }
  m = /^\$link\.ref\('([^']*)'\)$/.exec(target);
  if (m) return `#${m[1]}`;
  m = /^\$link\.url\('([^']*)'\)$/.exec(target);
  if (m) return m[1];
  return null;
}

function convert(file) {
  const text = readFileSync(join(src, file), "utf8");
  const { title, description, body } = frontMatter(text, file);
  const lines = body.split("\n");
  const res = [];
  let fence = null; // the opening fence while inside a code block
  let mermaidNext = false;
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    const fm = /^(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      res.push(line);
      if (fm && fm[1].startsWith(fence) && fm[2].trim() === "") fence = null;
      continue;
    }
    if (/^>\s*\[\]\(\$block\.attrs\(["']mermaid["']\)\)\s*$/.test(line)) {
      mermaidNext = true;
      continue;
    }
    if (fm) {
      fence = fm[1];
      let lang = fm[2].trim();
      if (mermaidNext) { lang = "mermaid"; mermaidNext = false; }
      if (lang === "=html") lang = "html";
      // A raw HTML block is kept as HTML, not shown as code.
      if (fm[2].trim() === "=html") {
        const end = lines.indexOf(fm[1], i + 1);
        res.push(...lines.slice(i + 1, end));
        i = end;
        fence = null;
        continue;
      }
      res.push(fm[1] + lang);
      continue;
    }
    if (mermaidNext && line.trim() !== "") throw new Error(`${file}:${i + 1}: $block.attrs("mermaid") must precede a fenced block`);
    // Headings: site "# x" is h2 under the page title.
    const h = /^(#{1,5}) (.*)$/.exec(line);
    if (h) {
      let text = h[2];
      const id = /^\[(.*)\]\(\$heading\.id\('[^']*'\)\)\s*$/.exec(text);
      if (id) text = id[1];
      line = `#${h[1]} ${text}`;
    }
    // Images, then links (not inside inline code).
    line = line.replace(/\[\]\(\$image\.siteAsset\('([^']*)'\)(?:\.alt\('([^']*)'\))?\)/g,
      (_, p, alt) => `![${alt || ""}](../site/assets/${p})`);
    line = line.replace(/\]\((\$link\.[^)]*\)(?:\.ref\('[^']*'\))?)\)/g, (all, target) => {
      const to = link(target);
      if (to === null) throw new Error(`${file}:${i + 1}: unknown link ${target}`);
      return `](${to})`;
    });
    if (/\$(link|image|heading|block)\./.test(line.replace(/`[^`]*`/g, "")))
      throw new Error(`${file}:${i + 1}: SuperMD the generator doesn't convert: ${line.trim()}`);
    res.push(line);
  }
  const head = `${marker}${file} by tools/docs/gen-md.mjs: edit that file. -->\n\n# ${title}\n\n${description ? description + "\n\n" : ""}`;
  return head + res.join("\n").replace(/^\n+/, "").replace(/\n*$/, "\n");
}

function readme() {
  let s = `${marker}*.smd by tools/docs/gen-md.mjs (index: site/docs-index.json). -->\n\n# Oriel documentation\n\n`;
  s += "The same pages as the website, https://oriel.foreachdeveloper.com/docs/.\n";
  for (const section of index) {
    s += `\n## ${section.section}\n\n`;
    for (const page of section.pages) {
      const { title, description } = frontMatter(readFileSync(join(src, `${page}.smd`), "utf8"), page);
      s += `- [${title}](${page}.md)${description ? `: ${description}` : ""}\n`;
    }
  }
  s += "\n## For contributors\n\n- [internal/](internal/): contributing, testing and porting notes\n- [design/](design/): design records of shipped and planned features\n";
  return s;
}

// The site's sidebar, between markers in the docs layout.
function sidebar(layout) {
  const begin = "<!-- oriel:sidebar begin (tools/docs/gen-md.mjs, from site/docs-index.json) -->";
  const end = "<!-- oriel:sidebar end -->";
  const a = layout.indexOf(begin), b = layout.indexOf(end);
  if (a < 0 || b < a) throw new Error("site/layouts/docs.shtml: no oriel:sidebar markers");
  const indent = "\t\t\t\t";
  let nav = "\n";
  for (const section of index) {
    nav += `${indent}<h4>${section.section}</h4>\n`;
    for (const page of section.pages) {
      const { title } = frontMatter(readFileSync(join(src, `${page}.smd`), "utf8"), page);
      nav += `${indent}<a href="$site.page('docs/${page}').link()">${title.replace(/&/g, "&amp;")}</a>\n`;
    }
  }
  nav += `${indent}<a href="$site.page('docs/changelog').link()">Changelog</a>\n${indent}`;
  return layout.slice(0, a + begin.length) + nav + layout.slice(b);
}

const want = new Map();
for (const f of readdirSync(src).filter((f) => f.endsWith(".smd")).sort()) {
  if (f === "index.smd" || f === "changelog.smd") continue; // the site's own pages
  want.set(`${basename(f, ".smd")}.md`, convert(f));
}
want.set("README.md", readme());

let stale = [];
const layoutPath = join(root, "site", "layouts", "docs.shtml");
const layout = readFileSync(layoutPath, "utf8");
const newLayout = sidebar(layout);
if (newLayout !== layout) {
  stale.push("site/layouts/docs.shtml (sidebar)");
  if (!check) writeFileSync(layoutPath, newLayout);
}
for (const [name, text] of want) {
  const path = join(out, name);
  const have = existsSync(path) ? readFileSync(path, "utf8") : null;
  if (have === text) continue;
  stale.push(name);
  if (!check) writeFileSync(path, text);
}
// Generated pages whose source is gone.
for (const name of readdirSync(out).filter((f) => f.endsWith(".md"))) {
  if (want.has(name)) continue;
  const text = readFileSync(join(out, name), "utf8");
  if (!text.startsWith(marker)) {
    stale.push(`${name} (hand-written at the top of docs/: move it to docs/internal/ or docs/design/, or make it a site page)`);
    continue;
  }
  stale.push(`${name} (no source)`);
  if (!check) unlinkSync(join(out, name));
}
if (check && stale.length) {
  console.error("docs/ is out of date with site/content/docs (run: node tools/docs/gen-md.mjs):\n  " + stale.join("\n  "));
  process.exit(1);
}
if (!check) console.log(stale.length ? `docs/: ${stale.length} updated` : "docs/: up to date");
