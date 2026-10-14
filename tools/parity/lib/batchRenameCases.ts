// Shared by the batch-rename-propose and batch-rename-plan suites: the reference module, name pools and random settings.

import type { Prng } from "./prng";
import { importReference } from "./reference";

export type Settings = Record<string, unknown>;
export type Item = {
  name: string;
  isFolder: boolean;
  createdAt: string | null;
  modifiedAt: string | null;
  takenAt: string | null;
};

// biome-ignore lint/suspicious/noExplicitAny: the reference module is loaded by path, without its types
export type BatchRenameModule = any;

export const NOW = "2026-10-04T11:32:10";

export function loadBatchRename(): Promise<BatchRenameModule> {
  return importReference("apps/desktop/src/shared/batchRename.ts");
}

export const DEFAULTS: Settings = {
  mode: "replace",
  find: "",
  replaceWith: "",
  matchCase: false,
  useRegex: false,
  addText: "",
  addWhere: "after",
  nameFormat: "index",
  formatWhere: "after",
  customName: "File",
  keepNames: false,
  startAt: 1,
  step: 1,
  digits: 5,
  separator: " ",
  dateSource: "created",
  dateFormat: "ymd",
  dateSeparator: "-",
  customDatePattern: "YYYY-MM-DD at HH.mm",
  caseStyle: "lower",
  applyTo: "name",
  onConflict: "number",
};

// Names with the cases that matter: accents written both ways, ß, dotted and Turkish i, Greek sigma, dotfiles,
// several dots, folders with dots, emoji, CJK, spaces at the ends, line breaks.
export const NAMES = [
  "IMG_2041.jpg", "IMG_2041.HEIC", "img_7.PNG", "notes.txt", "Notes.TXT", "a copy.txt", "report (1).pdf",
  "2026-10-04 notes.txt", "lisbon_12.jpg", "Café menu.pdf", "Café menu.pdf", "résumé.docx", "résumé.docx",
  "Straße.txt", "STRASSE.TXT", "İstanbul.txt", "istanbul.txt", "ISTANBUL.TXT", "ΟΔΥΣΣΕΑΣ.txt", "Σίσυφος.md", "ǆungla.txt",
  "ŉ.txt", "ﬁle.txt", ".env", ".config.json", "draft.", "README", "archive.tar.gz", "Tool.app", "photos.2026",
  "my-project_notes (draft).md", "élan vital", "2026 trip", "readMe file", "日本語.txt", "emoji 🎉 party.png",
  "👩‍👩‍👧‍👦 family.jpg", "a.b.c.d", "UPPER.TXT", "lower.txt", "MiXeD cAsE.Txt", "x", "a", "File 1.txt", "File 2.txt",
  "File 10.txt", "copy copy.txt", "  padded  .txt", "tab\there.md", "line\nbreak.txt", "dollar$sign.txt", "(1).txt",
  "[brackets].txt", "a  b   c.txt", "ſharp.txt", "KELVIN.txt", "Kelvin.txt", "Kelvin.txt", "ǅ.txt", "x.bak",
  "jpg photo.jpg", "jpeg.jpeg", "bbb.txt", "banana.txt", "aaa", "ab ab.ab",
];

export const DATES = [
  "2026-09-30T10:12:40", "2026-10-01T08:30:15", "2026-05-14T18:02:11", "2009-01-02T00:00:00", "1999-12-31T23:59:59",
  "2026-02-29T12:00:00", "0099-03-04T05:06:07",
];

export function makeItem(name: string, rng: Prng, isFolder = false): Item {
  const date = () => (rng.chance(0.12) ? null : rng.pick(DATES));
  return {
    name,
    isFolder,
    createdAt: date(),
    modifiedAt: date(),
    takenAt: rng.chance(0.5) ? null : rng.pick(DATES),
  };
}

const FIND_TEXT = [
  "IMG_", "img", "a", "copy", ".", "(1)", "é", "Café", "Café", "ss", "ß", "i", "İ", "σ", "ς", "k", "K", "K", "s",
  "ſ", "x", " ", "  ", "$", "$1", "[", "]", "\\", "notes", "File ", "jpg", "txt", "👩", "🎉", "日本", "ﬁ", "fi", "ǆ", "DŽ",
];
const REPLACEMENTS = ["", "x", "Lisbon ", "$1", "[one]", "_", "-", "  ", "é", "Café", ".", " copy", "SS", "ß", "😀", "$&"];

const PATTERNS = [
  "^IMG_(\\d+)$", "(\\d+)", "(\\d{4})-(\\d{2})-(\\d{2})", "(?<word>\\w+)_(?<n>\\d+)", "\\s+", "^", "$", "x*", "a*", "\\b",
  "\\bcopy\\b", "[aeiou]", "(.)\\1", "(?<=_)\\d", "(?<!^)[A-Z]", "(?!^)[A-Z]", "\\p{Lu}", "\\p{L}+", "\\P{L}", "é", "[^a-z0-9]",
  "\\.", ".", "\\w+", "\\W", "\\S+", "\\d{2,}", "a|", "(a)|(b)", "(a)?b", "[\\w.-]+", "^.", ".$", "[a-c-]", "\\u00e9", "\\u{1F389}",
  "\\x41", "\\d+(?=\\.)", "(?:ab)+", "a{2}", "a+?", "[\\s\\S]", "[^]", "[]", "\\/", "\\t", "(?<y>\\d{4})", "S+", "ss", "i", "k", "[k]",
  "\\w", "\\W+", "[\\u212A]", "\\bA", "(\\w)(\\w)", "(b)(c)?", "\\p{Script=Greek}", "\\p{Ll}", "[\\p{Lu}\\d]", "\\B", "^$", "(?:)",
  "\\u0301", "é", "\\n", "^a.*b$", "(.*)\\.(.*)$",
  "ﬁ", "[ß]", "(a|ab)(c|bcd)?", "[\\-a]", "\\u{1E9E}", "\\p{Lowercase}", "[\\u{1F389}-\\u{1F9FF}]", "\\ud83d\\ude00", "(?=(a))\\1",
  "a{0}", "\\cJ", "[\\w]+", "[^\\W]+", "(?<=\\d)x?", "\\Bs", "ǆ", "Ǆ", "ǅ",
];
const BAD_PATTERNS = [
  "(unclosed", "[", "a)", "*a", "a**", "a{2,1}", "\\", "(?<n>a)(?<n>b)", "\\k<x>", "(?z)", "\\q", "a{", "}", "]", "\\-", "(?=a)*",
  "[b-a]", "\\1", "\\p{Nope}", "a*+", "\\cA", "\\u{110000}", "(?<1a>x)",
];
const TEMPLATES = [
  "$1", "$2$1", "[$&]", "$`|$'", "$$", "$$1", "$<n>-$<word>", "$<word", "$<other>", "$3", "$10", "$11", "$0", "$01", "$", "cost $",
  "$x", "$<", "<$>", "", "x", "-", "$1$1", "\\1", "$<y>", "[$<y>]", "$100", "$9", "$&$&",
];

export function randomSettings(rng: Prng, mode?: string): Settings {
  const settings: Settings = { ...DEFAULTS };
  settings.mode = mode ?? rng.pick(["replace", "replace", "replace", "add", "format", "format", "case"]);
  settings.applyTo = rng.pick(["name", "name", "extension", "both"]);
  settings.matchCase = rng.chance(0.4);
  switch (settings.mode) {
    case "replace": {
      settings.useRegex = rng.chance(0.55);
      if (settings.useRegex) {
        settings.find = rng.chance(0.06) ? rng.pick(BAD_PATTERNS) : rng.pick(PATTERNS);
        settings.replaceWith = rng.chance(0.7) ? rng.pick(TEMPLATES) : rng.pick(REPLACEMENTS);
      } else {
        settings.find = rng.chance(0.85) ? rng.pick(FIND_TEXT) : Array.from(rng.pick(NAMES)).slice(0, rng.int(0, 5)).join("");
        settings.replaceWith = rng.chance(0.8) ? rng.pick(REPLACEMENTS) : rng.pick(TEMPLATES);
      }
      break;
    }
    case "add":
      settings.addText = rng.pick(["", " ", "   ", " (edited)", "old-", ".bak", "x", "é", "Café", ".", "\n", "😀", " copy", "_"]);
      settings.addWhere = rng.pick(["after", "before"]);
      break;
    case "case":
      settings.caseStyle = rng.pick(["lower", "upper", "title"]);
      break;
    case "format": {
      settings.applyTo = rng.pick(["name", "both"]);
      settings.nameFormat = rng.pick(["index", "counter", "date", "date"]);
      settings.formatWhere = rng.pick(["after", "before"]);
      settings.customName = rng.pick(["File", "Trip", "Lisbon", "é", "", " ", "Café", "日本", "a.b", "x".repeat(rng.int(1, 30))]);
      settings.keepNames = rng.chance(0.3);
      settings.startAt = rng.pick([0, 1, 1, 2, 7, 10, 99, 999_999_999]);
      settings.step = rng.pick([1, 1, 2, 5, 10, 1000]);
      settings.digits = rng.pick(["auto", 2, 3, 4, 5]);
      settings.separator = rng.pick([" ", "-", "_", ""]);
      settings.dateSource = rng.pick(["created", "modified", "taken", "today"]);
      settings.dateFormat = rng.pick(["ymd", "ymd_hm", "ymd_hms", "dmy", "dmyy", "mdy", "yymd", "ym", "custom", "custom"]);
      settings.dateSeparator = rng.pick(["-", "_", ".", " ", ""]);
      settings.customDatePattern = rng.pick([
        "YYYY-MM-DD at HH.mm", "YYYY-DD-MM at HH.mm.ss", "[Mission] YYYY", "Mission YYYY", "[YYYY", "[YYYY]", "today", "YY/MM", "[]YYYY",
        "[a][b]YYYY", "YYYYYY", "YYYYY", "Y", "ssmmHH", "[ss]ss", "YYYY]MM", "MM[", "[[YYYY]]DD", "DD MM YY", "yyyy", "",
      ]);
      break;
    }
  }
  if (rng.chance(0.15)) {
    settings.onConflict = rng.pick(["number", "skip", "block"]);
  }
  return settings;
}

// The part of an error that is the same on every JavaScript engine; the rest of its text is the engine's own.
export function normalizeError(error: string | null): string | null {
  if (error === null) {
    return null;
  }
  const prefix = "The pattern isn’t valid: ";
  return error.startsWith(prefix) ? prefix.trimEnd() : error;
}
