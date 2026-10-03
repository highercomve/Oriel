// The build's half of the sheet cache (tools/qjs_modules.zig): an app's
// style sheets parsed when it's built, as addSheet keeps them, so the first
// window reads them instead of parsing (host.sheetCache with the asset path).
import { sheetData } from "./css.js";

globalThis.__orielSheetJSON = (css) => JSON.stringify(sheetData(css));
