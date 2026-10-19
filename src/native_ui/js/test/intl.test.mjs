// intl.js against Node's ICU: the same text for the locales and options it
// covers (money in Chilean pesos and euros, numeric and named dates, times).
import assert from "node:assert/strict";
import { installIntl } from "../src/intl.js";
const real = globalThis.Intl;
const g = {}; installIntl(g, "es-CL");
const F = g.Intl;
const d = new Date(Date.UTC(2026, 9, 16, 15, 5, 9));
const cases = [
  ["NumberFormat", "es-CL", { style: "currency", currency: "CLP", maximumFractionDigits: 0 }, 53970],
  ["NumberFormat", "es-CL", { style: "currency", currency: "CLP", maximumFractionDigits: 0 }, -1234567],
  ["NumberFormat", "en-US", { style: "currency", currency: "USD" }, 1234.5],
  ["NumberFormat", "es-ES", { style: "currency", currency: "EUR" }, 1234.5],
  ["NumberFormat", "de-DE", { style: "currency", currency: "EUR" }, 1234.5],
  ["NumberFormat", "pt-BR", { style: "currency", currency: "BRL" }, 1234.5],
  ["NumberFormat", "en-US", {}, 1234567.891],
  ["NumberFormat", "es-CL", {}, 1234.5],
  ["NumberFormat", "es-CL", {}, 12345.5],
  ["NumberFormat", "en-US", { style: "percent" }, 0.256],
  ["NumberFormat", "es-CL", { style: "percent", maximumFractionDigits: 1 }, 0.256],
  ["DateTimeFormat", "en", { month: "long", year: "numeric", timeZone: "UTC" }, d],
  ["DateTimeFormat", "es-CL", { month: "long", year: "numeric", timeZone: "UTC" }, d],
  ["DateTimeFormat", "en-US", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" }, d],
  ["DateTimeFormat", "es-CL", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" }, d],
  ["DateTimeFormat", "en-US", { timeZone: "UTC" }, d],
  ["DateTimeFormat", "es-CL", { timeZone: "UTC" }, d],
  ["DateTimeFormat", "de-DE", { timeZone: "UTC" }, d],
  ["DateTimeFormat", "en-US", { dateStyle: "short", timeStyle: "short", timeZone: "UTC" }, d],
  ["DateTimeFormat", "es-CL", { dateStyle: "short", timeStyle: "short", timeZone: "UTC" }, d],
  ["DateTimeFormat", "en-US", { dateStyle: "medium", timeZone: "UTC" }, d],
  ["DateTimeFormat", "es-ES", { dateStyle: "long", timeZone: "UTC" }, d],
  ["DateTimeFormat", "en-US", { dateStyle: "full", timeZone: "UTC" }, d],
  ["DateTimeFormat", "es-ES", { dateStyle: "full", timeZone: "UTC" }, d],
  ["DateTimeFormat", "en-US", { hour: "numeric", minute: "2-digit", timeZone: "UTC" }, d],
  ["DateTimeFormat", "es-CL", { hour: "numeric", minute: "2-digit", timeZone: "UTC" }, d],
  ["DateTimeFormat", "fr-FR", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }, d],
];
let diff = 0;
for (const [ctor, loc, opts, v] of cases) {
  const a = new real[ctor](loc, opts).format(v), b = new F[ctor](loc, opts).format(v);
  const same = a === b;
  if (!same) diff++;
  if (!same) console.log(`${ctor} ${loc} ${JSON.stringify(opts)}: ICU ${JSON.stringify(a)}, ours ${JSON.stringify(b)}`);
}
assert.equal(diff, 0, "the same text as ICU");
// Penny Goblin's calls, through the methods intl.js installs.
assert.equal(new F.NumberFormat("es-CL", { style: "currency", currency: "CLP", maximumFractionDigits: 0 }).format(53970), "$53.970");
assert.equal(F.DateTimeFormat("en", { month: "long", year: "numeric", timeZone: "UTC" }).format(d), "October 2026", "callable without new");
assert.equal(new F.Collator("es", { sensitivity: "base" }).compare("árbol", "Arbol"), 0);
assert.ok(new F.Collator("es").compare("b", "á") > 0, "accents sort with their letter");
assert.equal(new F.PluralRules("en", { type: "ordinal" }).select(22), "two");
console.log("intl: " + cases.length + " formats match ICU; Collator and PluralRules pass");
