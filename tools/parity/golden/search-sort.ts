// Sorting search results (apps/desktop/src/renderer/lib/searchResults.ts, sortSearchResults) by name, path and kind,
// both ways, and the folder column and the highlight pattern of the same file.
// Input: { items: [{ id, path, name, extension, kind }], sortBy, direction }, or { folder: { path, rootPath } }, or
// { highlight: { query, patternMode, matchScope, texts } }.
// Output: the ids in order; the folder text; for a highlight the first match in each text (null for none) or null for
// no pattern.
// The order is the machine's locale's (localeCompare), so this is checked on a machine with the same locale.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Item = { id: number; path: string; name: string; extension: string; kind: string };
type Module = {
  sortSearchResults: (items: Item[], sortBy: string, direction: string) => Item[];
  formatSearchResultFolder: (path: string, rootPath: string) => string;
  buildSearchHighlightPattern: (query: string, patternMode: string, matchScope: string) => RegExp | null;
};

export const seed = 0x5ea4c003;
export const machineLocal = true;

const NAMES = [
  "a.ts", "A.ts", "b.ts", "B.TS", "ä.ts", "a.md", "Makefile", "makefile", "README.md", "readme.txt", "Résumé.pdf",
  "resume.pdf", "résumé.pdf", "Zeta", "zeta", "10.txt", "2.txt", "1.txt", "a-b.txt", "a_b.txt", "a b.txt", "ab.txt",
  ".hidden", ".env", "日本語.txt", "ñandú.doc", "nandu.doc", "Ωmega", "omega", "Straße.txt", "strasse.txt", "ǆ", "İstanbul",
  "istanbul", "😀.png", "x.tar.gz", "x.TAR.GZ", "y.", "z..", "[brackets].txt", "(paren).txt", "#hash", "~tilde", "_under",
  "Notes.app", "Utils.md", "utils.ts",
];
const FOLDERS = ["/Users/demo/project", "/Users/demo/project/src", "/Users/demo/project/Src", "/Users/demo/Évènement", "/Users/demo/evenement", "/a", "/"];
const KINDS = ["file", "directory", "bundle", "symlink_directory", "symlink_file"];

function extensionOf(name: string): string {
  const index = name.lastIndexOf(".");
  return index <= 0 ? "" : name.slice(index + 1).toLowerCase();
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const module = await importReference<Module>("apps/desktop/src/renderer/lib/searchResults.ts");
  const cases: GoldenCase[] = [];
  const sortCase = (items: Item[]) => {
    for (const sortBy of ["name", "path", "kind"]) {
      for (const direction of ["asc", "desc"]) {
        cases.push({
          name: `${cases.length}: ${sortBy} ${direction} of ${items.length}`,
          input: { items, sortBy, direction },
          output: module.sortSearchResults(items, sortBy, direction).map((item) => item.id),
        });
      }
    }
  };
  const make = (id: number, folder: string, name: string, kind: string): Item => ({
    id,
    path: `${folder === "/" ? "" : folder}/${name}`,
    name,
    extension: extensionOf(name),
    kind,
  });
  // Every name in one folder, then in several.
  sortCase(NAMES.map((name, id) => make(id, "/Users/demo/project", name, kind(name))));
  sortCase(NAMES.map((name, id) => make(id, FOLDERS[id % FOLDERS.length] as string, name, kind(name))));
  // The same name in different folders, and ties.
  sortCase(FOLDERS.flatMap((folder, index) => [make(index * 2, folder, "same.txt", "file"), make(index * 2 + 1, folder, "Same.txt", "file")]));
  for (let round = 0; round < 12; round += 1) {
    const items: Item[] = [];
    for (let id = 0; id < rng.int(2, 25); id += 1) {
      items.push(make(id, rng.pick(FOLDERS), rng.pick(NAMES), rng.pick(KINDS)));
    }
    sortCase(items);
  }
  // The folder column.
  const roots = ["/", "/Users/demo/project", "/Users/demo/project/", "/Users/demo//", "/Users/demo/Évènement"];
  const paths = ["/notes.txt", "/etc/hosts", "/Users/demo/project/README.md", "/Users/demo/project/src/lib/a.ts", "/Users/demo/project/src//b.ts", "/Users/demo/Évènement/x/y.txt", "/Users/demo/Évènement/z.txt", "/Users/demo/other/q.txt", "/Users/demo/project/a/b/c/d/e.txt"];
  for (const rootPath of roots) {
    for (const path of paths) {
      cases.push({
        name: `${cases.length}: folder ${path} from ${rootPath}`,
        input: { folder: { path, rootPath } },
        output: module.formatSearchResultFolder(path, rootPath),
      });
    }
  }
  // The highlight pattern.
  const texts = ["MyApp.tsx", "myapp.tsx", "report (1).pdf", "My C++ notes", "my c++ notes", "abc", "a.c", "Résumé", "résumé", "ǅ", "STRASSE"];
  const queries = ["app", "App", "*.ts", "src/app", "(", "(1).pdf", "c++", "C++", "a.c", "", "  ", " app ", "résumé", "Résumé", "\\d+", "[a-c]+", "a|b", "(?i)app", "[", "ss", "É", "é"];
  for (const patternMode of ["text", "glob", "regex"]) {
    for (const matchScope of ["name", "path"]) {
      for (const query of queries) {
        const pattern = module.buildSearchHighlightPattern(query, patternMode, matchScope);
        cases.push({
          name: `${cases.length}: highlight ${patternMode}/${matchScope} ${JSON.stringify(query)}`,
          input: { highlight: { query, patternMode, matchScope, texts } },
          output: pattern === null ? null : texts.map((text) => pattern.exec(text)?.[0] ?? null),
        });
      }
    }
  }
  return cases;

  function kind(name: string): string {
    return name.startsWith("Z") || name === "Notes.app" ? (name.endsWith(".app") ? "bundle" : "directory") : "file";
  }
}
