// proposeNames (apps/desktop/src/shared/batchRename.ts): the new name of every item for the Rename sheet's settings.
// Input: { settings, items: [{ name, isFolder, createdAt, modifiedAt, takenAt }], now }. Output: { settingsError, names }
// where settingsError is the engine-independent part of the message ("The pattern isn’t valid:" for a broken pattern; the
// rest of it is the JavaScript engine's own wording) and names are the reference's ProposedName values.

import type { GoldenCase } from "../lib/golden";
import {
  type BatchRenameModule,
  DEFAULTS,
  type Item,
  NAMES,
  NOW,
  type Settings,
  loadBatchRename,
  makeItem,
  normalizeError,
  randomSettings,
} from "../lib/batchRenameCases";
import type { Prng } from "../lib/prng";

export const seed = 0x6272_0001;

type Input = { settings: Settings; items: Item[]; now: string };

function run(mod: BatchRenameModule, input: Input): GoldenCase["output"] {
  const items = input.items.map((item) => ({ ...item, path: `/trip/${item.name}` }));
  const result = mod.proposeNames(input.settings, items, input.now);
  return { settingsError: normalizeError(result.settingsError), names: result.names };
}

const PLAIN = (name: string, extra: Partial<Item> = {}): Item => ({
  name,
  isFolder: false,
  createdAt: "2026-09-30T10:12:40",
  modifiedAt: "2026-10-01T08:30:15",
  takenAt: null,
  ...extra,
});

// Names the odd letters live in: always part of the cases that probe them.
const TRICKY = ["Straße.txt", "STRASSE.TXT", "İstanbul.txt", "ISTANBUL.TXT", "ΟΔΥΣΣΕΑΣ.txt", "Σίσυφος.md", "KELVIN.txt", "\u212Aelvin.txt", "ſharp.txt", "ﬁle.txt", "Café menu.pdf", "Cafe\u0301 menu.pdf", "ǆungla.txt", "ŉ.txt"];

const REGEX_TRICKY = ["Straße.txt", "STRASSE.TXT", "ﬁle.txt", "İstanbul.txt", "Σίσυφος.md", "\u212Aelvin.txt", "Café menu.pdf", "Cafe\u0301 menu.pdf"];

// `count` different names, so a case stays small whatever the pool holds.
function sample(rng: Prng, count: number, tricky = TRICKY): Item[] {
  const pool = [...NAMES];
  const picked: Item[] = [];
  while (picked.length < count && pool.length > 0) {
    picked.push(PLAIN(pool.splice(rng.int(0, pool.length - 1), 1)[0] as string));
  }
  return [...tricky.map((name) => PLAIN(name)), ...picked];
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const mod = await loadBatchRename();
  const cases: GoldenCase[] = [];
  const seen = new Set<string>();
  const add = (label: string, settings: Settings, items: Item[]) => {
    const input: Input = { settings: { ...DEFAULTS, ...settings }, items, now: NOW };
    const name = `${label} #${cases.length}`;
    if (seen.has(name)) {
      return;
    }
    seen.add(name);
    cases.push({ name, input, output: run(mod, input) });
  };

  // Hand-picked: case changes on the names that behave oddly, each style and scope.
  for (const caseStyle of ["lower", "upper", "title"]) {
    for (const applyTo of ["name", "extension", "both"]) {
      add(`case ${caseStyle} ${applyTo}`, { mode: "case", caseStyle, applyTo }, sample(rng, 10));
    }
  }
  // Replace: plain text, ignoring case or not, on accents and special letters.
  for (const find of ["ss", "SS", "ß", "i", "I", "İ", "ı", "σ", "ς", "Σ", "k", "K", "K", "s", "ſ", "é", "é", "ﬁ", "fi", "ǆ", "ǅ"]) {
    for (const matchCase of [false, true]) {
      add(`find ${JSON.stringify(find)} case=${matchCase}`, { find, replaceWith: "#", matchCase, applyTo: "both" }, sample(rng, 4));
    }
  }
  // Regex shapes the sheet's users write: groups, empty matches, anchors, escapes, classes, look-around, Unicode.
  for (const [find, replaceWith] of [
    ["^IMG_(\\d+)$", "Lisbon $1"], ["(\\d{4})-(\\d{2})-(\\d{2})", "$3.$2.$1"], ["(?<word>\\w+)_(?<n>\\d+)", "$<n> $<word>"],
    ["\\d+", "[$&]"], ["^", "2026 "], ["$", " end"], ["", "x"], ["x*", "-"], ["a*", "-"], ["\\b", "|"], ["\\B", "|"], ["(?:)", "+"],
    ["(.)\\1", "<$1>"], ["(a)|(b)", "[$1][$2]"], ["\\s+", "_"], ["\\p{Lu}", "($&)"], ["\\p{L}+", "<$&>"], [".", "."], ["$", "$$"],
    ["\\w", "w"], ["ﬁ", "#"], ["[ß]", "#"], ["ss", "#"], ["\\W", "-"], ["\\S+", "s"], ["[^]", "."], ["[]", "."], ["(b)(c)?", "[$1|$2|$`|$']"], ["é", "E"], ["é", "E"],
    ["\\u00e9", "E"], ["\\u0301", "~"], ["[\\u212A]", "kelvin"], ["\\bA", "a"], ["\\p{Script=Greek}+", "G"],
  ] as const) {
    for (const matchCase of [false, true]) {
      for (const applyTo of ["name", "both"]) {
        add(`regex ${JSON.stringify(find)} -> ${JSON.stringify(replaceWith)} case=${matchCase} ${applyTo}`,
          { find, replaceWith, useRegex: true, matchCase, applyTo }, sample(rng, 5, REGEX_TRICKY));
      }
    }
  }
  // Broken patterns and patterns the original's engine accepts or refuses.
  for (const find of ["(unclosed", "[", "a)", "*a", "a**", "a{2,1}", "\\", "(?<n>a)(?<n>b)", "\\k<x>", "(?z)", "\\q", "a{", "}", "]", "\\-", "[b-a]", "\\1", "\\p{Nope}", "(?<1a>x)"]) {
    add(`broken ${JSON.stringify(find)}`, { find, replaceWith: "x", useRegex: true }, [PLAIN("a.txt"), PLAIN("b{.txt")]);
  }
  // Format: dates, counters, separators and custom patterns.
  const dated = [
    PLAIN("IMG_2041.HEIC", { takenAt: "2026-05-14T18:02:11" }),
    PLAIN("notes.txt"),
    PLAIN("folder.2026", { isFolder: true, modifiedAt: null }),
    PLAIN("none.jpg", { createdAt: null, modifiedAt: null, takenAt: null }),
  ];
  for (const dateFormat of ["ymd", "ymd_hm", "ymd_hms", "dmy", "dmyy", "mdy", "yymd", "ym"]) {
    for (const dateSeparator of ["-", "_", ".", " ", ""]) {
      add(`date ${dateFormat} sep ${JSON.stringify(dateSeparator)}`, { mode: "format", nameFormat: "date", dateSource: "taken", dateFormat, dateSeparator }, dated);
    }
  }
  for (const customDatePattern of ["YYYY-MM-DD at HH.mm", "[Mission] YYYY", "Mission YYYY", "[YYYY", "[YYYY]", "today", "YY/MM", "[]YYYY", "YYYYYY", "ss", "[ss]ss"]) {
    for (const dateSource of ["created", "modified", "taken", "today"]) {
      add(`custom ${JSON.stringify(customDatePattern)} ${dateSource}`, { mode: "format", nameFormat: "date", dateFormat: "custom", customDatePattern, dateSource }, dated);
    }
  }

  // Random.
  while (cases.length < 600) {
    const settings = randomSettings(rng);
    const count = rng.pick([1, 1, 2, 3, 5, 8, 12]);
    const items: Item[] = [];
    for (let index = 0; index < count; index++) {
      const name = rng.pick(NAMES);
      items.push(makeItem(rng.chance(0.1) ? `${name}${rng.int(0, 99)}` : name, rng, rng.chance(0.12)));
    }
    add(`random ${String(settings.mode)}`, settings, items);
  }
  return cases;
}
