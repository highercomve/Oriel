// Intl for the native renderer: QuickJS has none. The common part of
// NumberFormat (decimal, percent, currency), DateTimeFormat (components,
// dateStyle/timeStyle, UTC or local time), Collator and PluralRules, and the
// toLocale*String methods over them, with locale data for English, Spanish,
// Portuguese, French, German and Italian (others format as English). What a
// page asks for beyond that is ignored, as an unknown option is.

const MONTHS = {
  en: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
  es: ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
  pt: ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"],
  fr: ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
  de: ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"],
  it: ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"],
};
const MONTHS_SHORT = {
  en: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  es: ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"],
  pt: ["jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez."],
  fr: ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."],
  de: ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."],
  it: ["gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic"],
};
const WEEKDAYS = {
  en: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
  es: ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"],
  pt: ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"],
  fr: ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"],
  de: ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"],
  it: ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"],
};
const WEEKDAYS_SHORT = {
  en: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
  es: ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"],
  pt: ["dom.", "seg.", "ter.", "qua.", "qui.", "sex.", "sáb."],
  fr: ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."],
  de: ["So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa."],
  it: ["dom", "lun", "mar", "mer", "gio", "ven", "sab"],
};
const NBSP = " ", NNBSP = " ";
// Separators: [group, decimal]. Regions where they differ from the language's.
const SEPARATORS = { en: [",", "."], es: [".", ","], pt: [".", ","], fr: [NNBSP, ","], de: [".", ","], it: [".", ","] };
const REGION_SEPARATORS = { "es-MX": [",", "."], "es-US": [",", "."], "es-PE": [",", "."], "pt-PT": [NNBSP, ","], "de-CH": ["’", "."], "fr-CH": [NNBSP, "."] };
// Spain's Spanish, Portugal's Portuguese and Italian group only from five
// digits (CLDR's minimumGroupingDigits 2): 1234, 12.345.
// Month first ("Oct 16, 2026", "10/16/2026"): North American English.
const usEnglish = (loc) => loc.lang === "en" && (!loc.region || ["US", "CA", "PH"].includes(loc.region));
const latinAmerican = (loc) => loc.lang === "es" && !!loc.region && loc.region !== "ES";
const groupsFromFive = (loc) => (loc.lang === "es" && !latinAmerican(loc)) || (loc.lang === "pt" && loc.region === "PT") || loc.lang === "it";
const CURRENCY_SYMBOLS = { USD: "US$", EUR: "€", GBP: "£", JPY: "¥", CLP: "CLP", MXN: "MX$", BRL: "R$", ARS: "ARS", COP: "COP", PEN: "PEN", CAD: "CA$", AUD: "A$", CHF: "CHF" };
// The local currency's symbol is "$" in its own countries, as CLDR has it.
const DOLLAR_REGIONS = { CLP: "CL", MXN: "MX", ARS: "AR", COP: "CO", USD: "US", CAD: "CA", AUD: "AU" };
const ZERO_DECIMALS = new Set(["CLP", "JPY", "KRW", "COP", "PYG", "ISK", "VND"]);

// "es-CL" → { lang: "es", region: "CL", tag: "es-CL" }; unknown languages are English's.
function parseLocale(locales, fallback) {
  const list = locales === undefined ? [] : Array.isArray(locales) ? locales : [locales];
  for (const raw of [...list, fallback, "en-US"]) {
    if (typeof raw !== "string" || !raw) continue;
    const parts = raw.replace(/_/g, "-").split("-");
    const lang = parts[0].toLowerCase();
    const region = parts.slice(1).find((p) => /^[A-Za-z]{2}$|^\d{3}$/.test(p))?.toUpperCase() || "";
    if (MONTHS[lang]) return { lang, region, tag: region ? `${lang}-${region}` : lang };
  }
  return { lang: "en", region: "US", tag: "en-US" };
}

function separators(loc) {
  return REGION_SEPARATORS[loc.tag] || SEPARATORS[loc.lang];
}

function group(digits, sep, loc) {
  if (groupsFromFive(loc) && digits.length <= 4) return digits;
  let out = "";
  for (let i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 === 0) out += sep;
    out += digits[i];
  }
  return out;
}

class NumberFormat {
  constructor(locales, options = {}) {
    this._loc = parseLocale(locales, defaultLocale());
    const o = options || {};
    this._style = o.style || "decimal";
    this._currency = o.currency ? String(o.currency).toUpperCase() : undefined;
    if (this._style === "currency" && !this._currency) throw new TypeError("Currency code is required with currency style.");
    this._display = o.currencyDisplay || "symbol";
    const curDigits = this._style === "currency" ? (ZERO_DECIMALS.has(this._currency) ? 0 : 2) : 0;
    const min = o.minimumFractionDigits ?? (this._style === "currency" ? curDigits : 0);
    let max = o.maximumFractionDigits ?? Math.max(min, this._style === "currency" ? curDigits : this._style === "percent" ? 0 : 3);
    if (max < min) max = min;
    this._min = min;
    this._max = max;
    this._grouping = o.useGrouping !== false;
    this._sign = o.signDisplay || "auto";
  }
  resolvedOptions() {
    return { locale: this._loc.tag, numberingSystem: "latn", style: this._style, currency: this._currency, minimumFractionDigits: this._min, maximumFractionDigits: this._max, useGrouping: this._grouping, signDisplay: this._sign };
  }
  format(value) { return this.formatToParts(value).map((p) => p.value).join(""); }
  formatToParts(value) {
    let n = typeof value === "bigint" ? Number(value) : Number(value);
    const parts = [];
    if (Number.isNaN(n)) return [{ type: "nan", value: "NaN" }];
    const negative = n < 0 || Object.is(n, -0);
    if (this._style === "percent") n *= 100;
    const abs = Math.abs(n);
    const [g, d] = separators(this._loc);
    let numberParts;
    if (!Number.isFinite(abs)) numberParts = [{ type: "infinity", value: "∞" }];
    else {
      let [int, frac = ""] = abs.toFixed(this._max).split(".");
      frac = frac.replace(/0+$/, "");
      while (frac.length < this._min) frac += "0";
      numberParts = [{ type: "integer", value: this._grouping ? group(int, g, this._loc) : int }];
      if (frac) numberParts.push({ type: "decimal", value: d }, { type: "fraction", value: frac });
    }
    const isZero = !numberParts.some((p) => (p.type === "integer" || p.type === "fraction") && /[1-9]/.test(p.value));
    const sign = this._sign === "never" ? "" : this._sign === "always" ? (negative ? "-" : "+")
      : this._sign === "exceptZero" ? (isZero ? "" : negative ? "-" : "+")
      : this._sign === "negative" ? (negative && !isZero ? "-" : "")
      : negative ? "-" : "";
    if (this._style === "currency") {
      const symbol = this._symbol();
      const before = this._loc.lang === "en" || latinAmerican(this._loc) || this._loc.tag === "pt-BR" || (this._loc.lang === "pt" && !this._loc.region);
      const space = this._loc.tag === "pt-BR" || this._loc.lang === "pt" ? NBSP : symbol.length > 1 && /^[A-Z]+$/.test(symbol) && this._loc.lang !== "en" ? NBSP : "";
      const signPart = sign ? [{ type: sign === "-" ? "minusSign" : "plusSign", value: sign }] : [];
      // Chile's: the sign after the symbol ("$-5").
      if (before && this._loc.tag === "es-CL") {
        parts.push({ type: "currency", value: symbol }, ...signPart, ...numberParts);
      } else if (before) {
        parts.push(...signPart, { type: "currency", value: symbol });
        if (space) parts.push({ type: "literal", value: space });
        parts.push(...numberParts);
      } else parts.push(...signPart, ...numberParts, { type: "literal", value: NBSP }, { type: "currency", value: symbol });
      return parts;
    }
    if (sign) parts.push({ type: sign === "-" ? "minusSign" : "plusSign", value: sign });
    parts.push(...numberParts);
    if (this._style === "percent") {
      if ((this._loc.lang === "es" && !latinAmerican(this._loc)) || this._loc.lang === "fr" || this._loc.lang === "de") parts.push({ type: "literal", value: NBSP });
      parts.push({ type: "percentSign", value: "%" });
    }
    return parts;
  }
  _symbol() {
    const c = this._currency;
    if (this._display === "code") return c;
    if (this._display === "narrowSymbol") return { EUR: "€", GBP: "£", JPY: "¥", BRL: "R$" }[c] || (DOLLAR_REGIONS[c] ? "$" : c);
    if (DOLLAR_REGIONS[c] && DOLLAR_REGIONS[c] === (this._loc.region || (c === "USD" && this._loc.lang === "en" ? "US" : ""))) return "$";
    if (c === "USD" && this._loc.lang === "en" && (!this._loc.region || this._loc.region === "US")) return "$";
    return CURRENCY_SYMBOLS[c] || c;
  }
  static supportedLocalesOf(locales) { return supported(locales); }
}

// 12-hour clocks: US English (and English without a region) and Latin American Spanish.
const twelveHour = (loc) => (loc.lang === "en" && (!loc.region || ["US", "CA", "AU", "PH", "IN"].includes(loc.region))) || latinAmerican(loc);

class DateTimeFormat {
  constructor(locales, options = {}) {
    this._loc = parseLocale(locales, defaultLocale());
    const o = { ...(options || {}) };
    this._utc = typeof o.timeZone === "string" && /^(utc|etc\/utc|gmt)$/i.test(o.timeZone);
    const components = ["weekday", "era", "year", "month", "day", "hour", "minute", "second"];
    if (!o.dateStyle && !o.timeStyle && !components.some((k) => o[k] !== undefined)) Object.assign(o, { year: "numeric", month: "numeric", day: "numeric" });
    this._o = o;
    this._h12 = o.hour12 ?? (o.hourCycle ? o.hourCycle === "h12" || o.hourCycle === "h11" : twelveHour(this._loc));
  }
  resolvedOptions() {
    return { locale: this._loc.tag, calendar: "gregory", numberingSystem: "latn", timeZone: this._utc ? "UTC" : localZone(), hour12: this._h12, ...this._o };
  }
  format(date) { return this.formatToParts(date).map((p) => p.value).join(""); }
  formatToParts(date) {
    const d = date === undefined ? new Date() : new Date(typeof date === "number" ? date : +date);
    if (Number.isNaN(+d)) throw new RangeError("Invalid time value");
    const f = this._fields(d);
    const o = this._o;
    if (o.dateStyle || o.timeStyle) {
      const out = [];
      if (o.dateStyle) {
        // Medium is numeric in German, Chile and Portugal: 05.01.2026.
        const numericMedium = o.dateStyle === "medium" && (this._loc.lang === "de" || this._loc.tag === "es-CL" || this._loc.tag === "pt-PT");
        const so = numericMedium ? { year: "numeric", month: "2-digit", day: "2-digit" } : styleOptions(o.dateStyle);
        if (o.dateStyle === "short" && fullShortYear(this._loc)) so.year = "numeric";
        out.push(...this._date(f, so));
      }
      if (o.dateStyle && o.timeStyle) out.push({ type: "literal", value: this._loc.lang === "fr" ? " " : ", " });
      if (o.timeStyle) out.push(...this._time(f, { hour: "numeric", minute: "2-digit", second: o.timeStyle === "short" ? undefined : "2-digit" }));
      return out;
    }
    const date_ = o.year || o.month || o.day || o.weekday ? this._date(f, o) : [];
    const time = o.hour || o.minute || o.second ? this._time(f, o) : [];
    if (date_.length && time.length) return [...date_, { type: "literal", value: ", " }, ...time];
    return date_.length ? date_ : time;
  }
  _fields(d) {
    const u = this._utc;
    return {
      year: u ? d.getUTCFullYear() : d.getFullYear(), month: u ? d.getUTCMonth() : d.getMonth(), day: u ? d.getUTCDate() : d.getDate(),
      weekday: u ? d.getUTCDay() : d.getDay(), hour: u ? d.getUTCHours() : d.getHours(), minute: u ? d.getUTCMinutes() : d.getMinutes(), second: u ? d.getUTCSeconds() : d.getSeconds(),
    };
  }
  _date(f, o) {
    const L = this._loc.lang;
    const two = (n) => String(n).padStart(2, "0");
    const out = [];
    const lit = (v) => out.push({ type: "literal", value: v });
    const year = o.year ? { type: "year", value: o.year === "2-digit" ? two(f.year % 100) : String(f.year) } : null;
    const day = o.day ? { type: "day", value: o.day === "2-digit" ? two(f.day) : String(f.day) } : null;
    const textMonth = o.month === "long" || o.month === "short" || o.month === "narrow";
    const monthName = (o.month === "long" ? MONTHS : MONTHS_SHORT)[L][f.month];
    const month = o.month ? { type: "month", value: textMonth ? (o.month === "narrow" ? MONTHS[L][f.month][0].toUpperCase() : monthName) : o.month === "2-digit" ? two(f.month + 1) : String(f.month + 1) } : null;
    const weekday = o.weekday ? { type: "weekday", value: (o.weekday === "long" ? WEEKDAYS : WEEKDAYS_SHORT)[L][f.weekday] } : null;
    if (weekday) { out.push(weekday); if (month || day || year) lit(L === "de" ? ", " : ", "); }
    if (!textMonth && month) {
      // Numeric: M/D/Y in US English, Y-M-D nowhere here; D/M/Y (D.M.Y in German, D-M-Y in Chile) elsewhere.
      const sep = L === "de" ? "." : this._loc.tag === "es-CL" ? "-" : "/";
      const order = usEnglish(this._loc) ? [month, day, year] : [day, month, year];
      const pad = this._loc.tag === "es-CL" || L === "fr" || L === "pt" || L === "it" || (L === "en" && !usEnglish(this._loc));
      order.filter(Boolean).forEach((p, i) => {
        if (i) lit(sep);
        out.push(pad && p.type !== "year" && !o[p.type]?.includes?.("2") ? { ...p, value: two(p.value) } : p);
      });
      return out;
    }
    if (usEnglish(this._loc)) {
      // October 16, 2026 · Oct 16 · October 2026
      if (month) out.push(month);
      if (day) { if (month) lit(" "); out.push(day); }
      if (year) { if (day) lit(", "); else if (month) lit(" "); out.push(year); }
      return out;
    }
    // 16 de octubre de 2026 (es, pt with a long month) · 16 oct 2026 · 16. Oktober 2026 · octubre de 2026
    const de_ = (L === "es" && o.month === "long") || L === "pt" ? " de " : " ";
    if (day) { out.push(day); if (L === "de") lit("."); if (month) lit(L === "de" ? " " : de_); }
    if (month) out.push(month);
    if (year) { if (month) lit(de_); else if (day) lit(" "); out.push(year); }
    return out;
  }
  _time(f, o) {
    const out = [];
    const two = (n) => String(n).padStart(2, "0");
    let h = f.hour;
    let period = null;
    if (this._h12) { period = h < 12 ? "AM" : "PM"; h = h % 12 || 12; }
    if (o.hour) out.push({ type: "hour", value: o.hour === "2-digit" || (!this._h12 && o.minute) ? two(h) : String(h) });
    if (o.minute) { if (o.hour) out.push({ type: "literal", value: ":" }); out.push({ type: "minute", value: two(f.minute) }); }
    if (o.second) { out.push({ type: "literal", value: ":" }, { type: "second", value: two(f.second) }); }
    if (period && o.hour) {
      const es = this._loc.region === "MX" || this._loc.region === "US" ? ["a.m.", "p.m."] : ["a. m.", "p. m."];
      out.push({ type: "literal", value: " " }, { type: "dayPeriod", value: this._loc.lang === "es" ? es[period === "AM" ? 0 : 1] : period });
    }
    return out;
  }
  static supportedLocalesOf(locales) { return supported(locales); }
}

function styleOptions(style) {
  switch (style) {
    case "full": return { weekday: "long", year: "numeric", month: "long", day: "numeric" };
    case "long": return { year: "numeric", month: "long", day: "numeric" };
    case "medium": return { year: "numeric", month: "short", day: "numeric" };
    default: return { year: "2-digit", month: "numeric", day: "numeric" };
  }
}
// pt-BR's and en-GB's short dates keep the full year.
const fullShortYear = (loc) => loc.tag === "pt-BR" || loc.tag === "en-GB";

// Accents and case per sensitivity (base: neither; accent: accents; case: case).
class Collator {
  constructor(locales, options = {}) {
    this._loc = parseLocale(locales, defaultLocale());
    this._sens = options?.sensitivity || "variant";
    this._numeric = !!options?.numeric;
    this.compare = this.compare.bind(this);
  }
  resolvedOptions() { return { locale: this._loc.tag, usage: "sort", sensitivity: this._sens, numeric: this._numeric }; }
  compare(a, b) {
    const key = (s) => {
      let k = String(s);
      if (this._sens === "base" || this._sens === "case") k = k.normalize("NFD").replace(/[̀-ͯ]/g, "");
      if (this._sens === "base" || this._sens === "accent") k = k.toLowerCase();
      return k;
    };
    const x = key(a), y = key(b);
    if (this._numeric) {
      const re = /(\d+)|(\D+)/g;
      const xs = x.match(re) || [], ys = y.match(re) || [];
      for (let i = 0; i < Math.min(xs.length, ys.length); i++) {
        if (xs[i] === ys[i]) continue;
        if (/^\d/.test(xs[i]) && /^\d/.test(ys[i])) return Math.sign(+xs[i] - +ys[i]) || (xs[i] < ys[i] ? -1 : 1);
        return base(xs[i], ys[i]);
      }
      return Math.sign(xs.length - ys.length);
    }
    return base(x, y);
  }
  static supportedLocalesOf(locales) { return supported(locales); }
}

// Dictionary order: letters ignoring accents and case first, then accents, then case.
function base(x, y) {
  const fold = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
  const fx = fold(x), fy = fold(y);
  if (fx !== fy) return fx < fy ? -1 : 1;
  const ax = x.normalize("NFD").toLowerCase(), ay = y.normalize("NFD").toLowerCase();
  if (ax !== ay) return ax < ay ? -1 : 1;
  return x === y ? 0 : x < y ? 1 : -1; // lower case first
}

class PluralRules {
  constructor(locales, options = {}) {
    this._loc = parseLocale(locales, defaultLocale());
    this._type = options?.type || "cardinal";
  }
  resolvedOptions() { return { locale: this._loc.tag, type: this._type }; }
  select(n) {
    n = Number(n);
    if (this._type === "ordinal") {
      if (this._loc.lang !== "en") return "other";
      const m10 = n % 10, m100 = n % 100;
      return m10 === 1 && m100 !== 11 ? "one" : m10 === 2 && m100 !== 12 ? "two" : m10 === 3 && m100 !== 13 ? "few" : "other";
    }
    if (this._loc.lang === "fr" || this._loc.lang === "pt") return n >= 0 && n < 2 ? "one" : "other";
    return n === 1 ? "one" : "other";
  }
  static supportedLocalesOf(locales) { return supported(locales); }
}

function supported(locales) {
  const list = locales === undefined ? [] : Array.isArray(locales) ? locales : [locales];
  return list.filter((l) => typeof l === "string" && MONTHS[l.split(/[-_]/)[0].toLowerCase()]);
}

let defaultTag = "en-US";
function defaultLocale() { return defaultTag; }
function localZone() {
  const off = -new Date().getTimezoneOffset();
  return off === 0 ? "UTC" : `Etc/GMT${off > 0 ? "-" : "+"}${Math.abs(off / 60)}`;
}

// Install Intl (when the engine has none) and the toLocale*String methods
// over it; `locale`: the user's language tag ("es-CL").
export function installIntl(g, locale) {
  defaultTag = parseLocale(locale, "en-US").tag;
  if (typeof g.Intl === "object" && g.Intl?.NumberFormat) return;
  const Intl = {
    NumberFormat, DateTimeFormat, Collator, PluralRules,
    getCanonicalLocales: (l) => (l === undefined ? [] : (Array.isArray(l) ? l : [l]).map((x) => parseLocale(x, x).tag)),
  };
  // Callable without new, as the built-ins are.
  for (const name of ["NumberFormat", "DateTimeFormat", "Collator", "PluralRules"]) {
    const C = Intl[name];
    const callable = function (locales, options) { return new C(locales, options); };
    callable.prototype = C.prototype;
    callable.supportedLocalesOf = C.supportedLocalesOf;
    Object.defineProperty(C.prototype, "constructor", { value: callable, configurable: true, writable: true });
    Intl[name] = callable;
  }
  g.Intl = Intl;
  const define = (proto, name, fn) => Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true });
  define(Number.prototype, "toLocaleString", function (locales, options) { return new NumberFormat(locales, options).format(this); });
  if (typeof BigInt === "function") define(BigInt.prototype, "toLocaleString", function (locales, options) { return new NumberFormat(locales, options).format(this); });
  define(Date.prototype, "toLocaleDateString", function (locales, options) {
    const o = { ...(options || {}) };
    if (!o.dateStyle && !["weekday", "year", "month", "day"].some((k) => o[k] !== undefined)) Object.assign(o, { year: "numeric", month: "numeric", day: "numeric" });
    return new DateTimeFormat(locales, o).format(this);
  });
  define(Date.prototype, "toLocaleTimeString", function (locales, options) {
    const o = { ...(options || {}) };
    if (!o.timeStyle && !["hour", "minute", "second"].some((k) => o[k] !== undefined)) Object.assign(o, { hour: "numeric", minute: "2-digit", second: "2-digit" });
    return new DateTimeFormat(locales, o).format(this);
  });
  define(Date.prototype, "toLocaleString", function (locales, options) {
    const o = { ...(options || {}) };
    if (!o.dateStyle && !o.timeStyle && !["weekday", "year", "month", "day", "hour", "minute", "second"].some((k) => o[k] !== undefined)) {
      Object.assign(o, { year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "2-digit", second: "2-digit" });
    }
    return new DateTimeFormat(locales, o).format(this);
  });
  define(String.prototype, "localeCompare", function (that, locales, options) { return new Collator(locales, options).compare(String(this), String(that)); });
}
