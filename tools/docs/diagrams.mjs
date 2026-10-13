#!/usr/bin/env node
// The docs' diagrams as images. A page keeps its diagram as Mermaid text
// (`>[]($block.attrs("mermaid"))` and a fenced block, reviewed with the
// code); this renders each to site/assets/diagrams/<page>-<n>.svg and a
// -dark.svg twin, which the site shows instead of drawing Mermaid in the
// browser (site/assets/site.js: readable at any width, tap to enlarge).
//
//   node tools/docs/diagrams.mjs           render what changed (needs Chrome)
//   node tools/docs/diagrams.mjs --check   exit 1 when an image is missing or
//                                          stale (CI; no browser)
//
// site/assets/diagrams/manifest.json keeps each image's source hash, so only
// changed diagrams render again; the images are listed in zine.ziggy's
// static_assets (zine publishes only assets it knows of). Rendering uses
// @mermaid-js/mermaid-cli (tools/docs: `npm install`) with the system's
// Chrome (CHROME, else google-chrome-stable / chromium on PATH).

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, unlinkSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const pages = join(root, "site", "content", "docs");
const outDir = join(root, "site", "assets", "diagrams");
const zineFile = join(root, "zine.ziggy");
const manifestFile = join(outDir, "manifest.json");
const check = process.argv.includes("--check");

// The look, in both themes (a change here renders every diagram again).
const STYLE = { version: 1, fontSize: "17px", fontFamily: "Inter, ui-sans-serif, system-ui, sans-serif" };
const THEMES = {
  light: { theme: "neutral", themeVariables: { fontSize: STYLE.fontSize, fontFamily: STYLE.fontFamily } },
  dark: {
    theme: "dark",
    themeVariables: {
      fontSize: STYLE.fontSize, fontFamily: STYLE.fontFamily,
      background: "#161922", primaryColor: "#222736", primaryBorderColor: "#4a5068",
      primaryTextColor: "#f3eee4", lineColor: "#9aa0b4", textColor: "#f3eee4",
      clusterBkg: "#1b1f2b", clusterBorder: "#3a3f52", noteBkgColor: "#2b3042", noteTextColor: "#f3eee4",
      actorBkg: "#222736", actorBorder: "#4a5068", actorTextColor: "#f3eee4", signalColor: "#c8ccd8", signalTextColor: "#f3eee4",
    },
  },
};

// Every diagram: [{ name, source }] in page order, "<page>-<n>".
function diagrams() {
  const out = [];
  for (const file of readdirSync(pages).filter((f) => f.endsWith(".smd")).sort()) {
    const lines = readFileSync(join(pages, file), "utf8").split("\n");
    let n = 0;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim() !== '>[]($block.attrs("mermaid"))') continue;
      const open = lines[i + 1] || "";
      if (!open.startsWith("```")) throw new Error(`${file}:${i + 2}: a mermaid block needs a fenced block right below`);
      let j = i + 2;
      while (j < lines.length && !lines[j].startsWith("```")) j++;
      n += 1;
      out.push({ name: `${basename(file, ".smd")}-${n}`, source: lines.slice(i + 2, j).join("\n").trim() });
      i = j;
    }
  }
  return out;
}

// Mermaid's svg is width="100%" with a max-width style: as an <img> it has
// no natural size. Its viewBox's instead, so the viewer can show it 1:1.
function sized(svg) {
  const vb = /viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"/.exec(svg);
  if (!vb) return svg;
  return svg.replace(/<svg([^>]*?) width="100%"/, `<svg$1 width="${Math.ceil(+vb[1])}" height="${Math.ceil(+vb[2])}"`)
    .replace(/(<svg[^>]*?) style="max-width: [\d.]+px;?"/, "$1");
}

const hashOf = (source) => createHash("sha256").update(JSON.stringify(STYLE) + "\n" + source).digest("hex").slice(0, 16);
const filesOf = (name) => [`${name}.svg`, `${name}-dark.svg`];

// zine.ziggy's static_assets: what was there besides the diagrams, then the
// images in order.
function zineWith(names) {
  const text = readFileSync(zineFile, "utf8");
  const m = /( *)\.static_assets = \[\n([\s\S]*?)\n?( *)\],/.exec(text);
  if (!m) throw new Error("zine.ziggy: no .static_assets list");
  const pad = m[1] + "    ";
  const others = m[2].split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith('"diagrams/'));
  const list = [...others, ...names.flatMap(filesOf).map((f) => `"diagrams/${f}",`)].map((l) => pad + l + "\n").join("");
  return text.replace(m[0], `${m[1]}.static_assets = [\n${list}${m[3]}],`);
}

const all = diagrams();
const manifest = existsSync(manifestFile) ? JSON.parse(readFileSync(manifestFile, "utf8")) : {};
const stale = all.filter((d) => manifest[d.name] !== hashOf(d.source) || filesOf(d.name).some((f) => !existsSync(join(outDir, f))));
const zine = zineWith(all.map((d) => d.name));
const extra = existsSync(outDir) ? readdirSync(outDir).filter((f) => f.endsWith(".svg") && !all.some((d) => filesOf(d.name).includes(f))) : [];

if (check) {
  const problems = [
    ...stale.map((d) => `${d.name}: missing or out of date`),
    ...extra.map((f) => `${f}: no diagram makes it any more`),
    ...(zine !== readFileSync(zineFile, "utf8") ? ["zine.ziggy: static_assets doesn't list the diagrams"] : []),
  ];
  if (problems.length) {
    console.error(`diagrams are out of date (run: node tools/docs/diagrams.mjs):\n  ${problems.join("\n  ")}`);
    process.exit(1);
  }
  process.exit(0);
}

mkdirSync(outDir, { recursive: true });
if (stale.length) {
  const { renderMermaid } = await import("@mermaid-js/mermaid-cli");
  const puppeteer = (await import("puppeteer")).default;
  const chrome = process.env.CHROME || ["google-chrome-stable", "google-chrome", "chromium", "chromium-browser"].map((c) => {
    try { return execFileSync("which", [c], { encoding: "utf8" }).trim(); } catch { return ""; }
  }).find(Boolean);
  if (!chrome) throw new Error("no Chrome found: set CHROME to its path");
  const browser = await puppeteer.launch({ executablePath: chrome, headless: true, args: ["--no-sandbox"] });
  try {
    for (const d of stale) {
      for (const [theme, config] of Object.entries(THEMES)) {
        const { data } = await renderMermaid(browser, d.source, "svg", {
          mermaidConfig: { ...config, deterministicIds: true, deterministicIDSeed: d.name, securityLevel: "strict" },
          backgroundColor: "transparent",
          svgId: `${d.name}-${theme}`,
        });
        writeFileSync(join(outDir, theme === "light" ? `${d.name}.svg` : `${d.name}-dark.svg`), sized(Buffer.from(data).toString("utf8")));
      }
      manifest[d.name] = hashOf(d.source);
      console.log(`rendered ${d.name}`);
    }
  } finally {
    await browser.close();
  }
}
for (const f of extra) unlinkSync(join(outDir, f));
for (const name of Object.keys(manifest)) if (!all.some((d) => d.name === name)) delete manifest[name];
writeFileSync(manifestFile, JSON.stringify(Object.fromEntries(Object.entries(manifest).sort()), null, 1) + "\n");
writeFileSync(zineFile, zine);
console.log(`diagrams: ${all.length} (${stale.length} rendered, ${extra.length} removed)`);
