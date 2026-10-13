// The list filter (apps/desktop/src/renderer/lib/listFilter.ts): names containing the text, search
// results by name or folder, the item the filter selects, and the item count text.
// Input: { entries: [{ id, name, relativeParentPath }], query, shown, total }.
// Output: { byName, bySearch, selection, count } (ids kept, in order; selection an id or null).

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Entry = { id: number; name: string; relativeParentPath: string };
type ListFilterModule = {
  filterEntriesByName: (entries: Entry[], query: string) => Entry[];
  filterSearchResultsByText: (entries: Entry[], query: string) => Entry[];
  findListFilterSelection: (entries: Entry[], query: string) => Entry | null;
  formatItemCount: (shown: number, total: number) => string;
};

export const seed = 0x11f70006;

const NAMES = [
  "Android", "Documents", "my doc.txt", "report (1).pdf", "C++ notes", "README.md", "readme.txt", "Résumé.pdf",
  "résumé final.docx", "Café.txt", "Café.txt", "ÉCOLE", "école", "İstanbul", "ISTANBUL", "ǅ", "STRASSE", "Straße",
  "日本語.txt", "🎉 party", "a.b", "a b", "A", "src-notes.md", "App.tsx", "App.test.tsx", ".hidden", "", "x", "Σίσυφος", "ΣΑΣ",
];
const FOLDERS = ["", "src/components", "tests", "docs", "docs/Résumé", "Src", "a/b/c", "日本語", "node_modules/.bin"];
const QUERIES = [
  "", "d", "DO", "doc", "y d", "(1)", "c++", "zzz", "re", "RE", "é", "e", "é", "É", "i", "I", "İ", "ss", "ß", "src", "SRC", "tests",
  ".", "a.", " ", "  ", "🎉", "日", "σ", "Σ", "ς", "app", "App", "txt", "/",
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const module = await importReference<ListFilterModule>("apps/desktop/src/renderer/lib/listFilter.ts");
  const cases: GoldenCase[] = [];
  const add = (entries: Array<[string, string]>, query: string, shown: number, total: number) => {
    const list: Entry[] = entries.map(([name, relativeParentPath], id) => ({ id, name, relativeParentPath }));
    const ids = (items: Entry[]) => items.map((item) => item.id);
    const byName = module.filterEntriesByName(list, query);
    cases.push({
      name: `${cases.length}: ${JSON.stringify(query)} in ${list.length}`,
      input: { entries: list, query, shown, total },
      output: {
        byName: ids(byName),
        bySearch: ids(module.filterSearchResultsByText(list, query)),
        selection: module.findListFilterSelection(byName, query)?.id ?? null,
        count: module.formatItemCount(shown, total),
      },
    });
  };

  // Every query against the fixed list of names.
  const fixed: Array<[string, string]> = NAMES.map((name, index) => [name, FOLDERS[index % FOLDERS.length] as string]);
  for (const query of QUERIES) {
    add(fixed, query, 0, 0);
  }
  add([], "x", 0, 0);
  add([], "", 3, 240);
  for (const [shown, total] of [[240, 240], [1, 1], [3, 240], [0, 1], [0, 0], [1, 2], [2, 1], [1000, 123456]]) {
    add(fixed.slice(0, 3), "", shown as number, total as number);
  }
  while (cases.length < 200) {
    const entries = Array.from({ length: rng.int(0, 12) }, (): [string, string] => [rng.pick(NAMES), rng.pick(FOLDERS)]);
    const pickedName = entries.length > 0 ? rng.pick(entries)[0] : "x";
    const query = rng.chance(0.4) ? rng.pick(QUERIES) : [...pickedName].slice(rng.int(0, 2), rng.int(2, 7)).join("");
    const total = rng.int(0, 300);
    add(entries, query, rng.int(0, total), total);
  }
  return cases;
}
