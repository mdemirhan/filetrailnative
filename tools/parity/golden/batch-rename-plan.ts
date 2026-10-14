// planBatchRename (apps/desktop/src/shared/batchRename.ts): the plan for items in folders whose names are known, with
// the conflict policy (number, skip, block), case-sensitive or not, and items that can't be renamed.
// Input: { settings, items: [{ path, name, isFolder, createdAt, modifiedAt, takenAt }], folders: { path: { names,
// caseSensitive } }, cannotRename: { path: message }, now }. Output: the reference's plan, with settingsError cut down
// to the engine-independent part of its message (see batch-rename-propose).

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

export const seed = 0x6272_0002;

type PlanItem = Item & { path: string };
type Folder = { names: string[]; caseSensitive: boolean };
type Input = {
  settings: Settings;
  items: PlanItem[];
  folders: Record<string, Folder>;
  cannotRename: Record<string, string>;
  now: string;
};

function run(mod: BatchRenameModule, input: Input): GoldenCase["output"] {
  const plan = mod.planBatchRename({
    settings: input.settings,
    items: input.items,
    folders: new Map(Object.entries(input.folders)),
    cannotRename: new Map(Object.entries(input.cannotRename)),
    now: input.now,
  });
  return { ...plan, settingsError: normalizeError(plan.settingsError) };
}

const FOLDERS = ["/trip", "/trip/sub", "/other"];
// Names a rename is likely to want, so folders hold some of them already.
const WANTED = [
  "File 1.txt", "File 2.txt", "File 3.txt", "file 1.txt", "FILE 2.TXT", "File 1", "File 2", "File 00001.txt", "Lisbon.jpg",
  "Lisbon 2.jpg", "Lisbon 3.jpg", "lisbon.jpg", "x 1.txt", "A.txt", "a.TXT", "a.txt", "Café.txt", "Café.txt", "café.txt",
  "File 2026-09-30.jpg", "File 2026-09-30 2.jpg", "File_1.txt", "bb", "aa", ".hidden", "notes.txt", "IMG_1.jpg", "IMG_2.jpg",
  "Straße.txt", "STRASSE.TXT", "2026 notes.txt", "draft notes.txt", "x copy.txt",
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const mod = await loadBatchRename();
  const cases: GoldenCase[] = [];
  const seen = new Set<string>();
  const add = (label: string, input: Input) => {
    const name = `${label} #${cases.length}`;
    if (seen.has(name)) {
      return;
    }
    seen.add(name);
    cases.push({ name, input, output: run(mod, input) });
  };
  const item = (folder: string, name: string, extra: Partial<Item> = {}): PlanItem => ({
    path: `${folder}/${name}`,
    name,
    isFolder: false,
    createdAt: "2026-09-30T10:12:40",
    modifiedAt: "2026-10-01T08:30:15",
    takenAt: null,
    ...extra,
  });
  const base = (settings: Settings, items: PlanItem[], folders: Record<string, Folder>, cannotRename: Record<string, string> = {}): Input => ({
    settings: { ...DEFAULTS, ...settings },
    items,
    folders,
    cannotRename,
    now: NOW,
  });
  const one = (folder: string, names: string[], caseSensitive = false): Record<string, Folder> => ({ [folder]: { names, caseSensitive } });

  // Hand-picked: the cases the original's own tests and its notes list.
  const skip = { onConflict: "skip" };
  add("number past taken", base({ find: "IMG_", replaceWith: "Lisbon " }, [item("/trip", "IMG_1.jpg")], one("/trip", ["IMG_1.jpg", "Lisbon 1.jpg", "Lisbon 1 2.jpg", ".hidden"])));
  add("number within the batch, format separator", base({ mode: "format", nameFormat: "date", separator: "_", customName: "Trip" }, [item("/trip", "a.jpg"), item("/trip", "b.jpg"), item("/trip", "c.png")], one("/trip", ["a.jpg", "b.jpg", "c.png"])));
  add("case and accents, insensitive", base({ find: "x", replaceWith: "" }, [item("/trip", "Ax.txt")], one("/trip", ["Ax.txt", "a.TXT"])));
  add("case and accents, sensitive", base({ find: "x", replaceWith: "" }, [item("/trip", "Ax.txt")], one("/trip", ["Ax.txt", "a.TXT"], true)));
  add("accent written two ways", base({ find: "x", replaceWith: "" }, [item("/trip", "cafxé.txt")], one("/trip", ["cafxé.txt", "café.txt"])));
  add("swap on a case-sensitive disk", base({ mode: "case", caseStyle: "upper", applyTo: "both" }, [item("/trip", "a"), item("/trip", "A.TXT")], one("/trip", ["a", "A.TXT"], true)));
  add("reorder", base({ mode: "format" }, [item("/trip", "File 2"), item("/trip", "File 1")], one("/trip", ["File 1", "File 2"])));
  add("skip chain", base({ ...skip, useRegex: true, find: "^(.)$", replaceWith: "$1$1" }, [item("/trip", "a"), item("/trip", "b")], one("/trip", ["a", "b", "bb"])));
  add("skip both", base({ ...skip, useRegex: true, find: "^(a|b)$", replaceWith: "$1x" }, [item("/trip", "a"), item("/trip", "b")], one("/trip", ["a", "b", "ax", "bx"])));
  add("skip cascade", base({ ...skip, mode: "format" }, [item("/trip", "x.txt"), item("/trip", "File 1.txt")], one("/trip", ["x.txt", "File 1.txt", "File 2.txt"])));
  const files = Array.from({ length: 12 }, (_, index) => `File ${index + 1}.txt`);
  add("skip a whole batch", base({ ...skip, mode: "format", startAt: 2 }, files.slice(0, 11).map((name) => item("/trip", name)), one("/trip", files)));
  add("block", base({ find: "IMG_", replaceWith: "Lisbon ", onConflict: "block" }, [item("/trip", "IMG_1.jpg"), item("/trip", "IMG_2.jpg")], one("/trip", ["IMG_1.jpg", "IMG_2.jpg", "Lisbon 1.jpg"])));
  add("block in batch", base({ mode: "format", nameFormat: "date", onConflict: "block" }, [item("/trip", "a.jpg"), item("/trip", "b.jpg")], one("/trip", ["a.jpg", "b.jpg"])));
  add("invalid slash", base({ find: "-", replaceWith: "/" }, [item("/trip", "a-b.txt")], one("/trip", ["a-b.txt"])));
  add("too long", base({ mode: "add", addText: "x".repeat(260) }, [item("/trip", "a.txt")], one("/trip", ["a.txt"])));
  add("dots", base({ find: "a", replaceWith: ".", applyTo: "both" }, [item("/trip", "a")], one("/trip", ["a"])));
  add("only an extension", base({ find: "notes", replaceWith: "" }, [item("/trip", "notes.txt")], one("/trip", ["notes.txt"])));
  add("locked", base({ mode: "format", customName: "x" }, [item("/trip", "locked.txt"), item("/trip", "b.txt")], one("/trip", ["locked.txt", "b.txt"]), { "/trip/locked.txt": "The item is locked." }));
  add("locked name wanted", base({ find: "draft", replaceWith: "locked" }, [item("/trip", "locked.txt"), item("/trip", "draft.txt")], one("/trip", ["locked.txt", "draft.txt"]), { "/trip/locked.txt": "The item is locked." }));
  const long = `${"a".repeat(251)}.txt`;
  add("number shortens", base({ find: "x", replaceWith: "a".repeat(251) }, [item("/trip", "x.txt")], one("/trip", ["x.txt", long])));
  add("number can't shorten", base({ find: "x", replaceWith: "y" }, [item("/trip", `x.${"e".repeat(252)}`)], one("/trip", [`x.${"e".repeat(252)}`, `y.${"e".repeat(252)}`])));
  add("number shortens multibyte", base({ find: "x", replaceWith: "日".repeat(84) }, [item("/trip", "x.txt")], one("/trip", ["x.txt", `${"日".repeat(84)}.txt`])));
  add("hidden", base({ mode: "add", addText: ".", addWhere: "before" }, [item("/trip", "config"), item("/trip", ".git")], one("/trip", ["config", ".git"])));
  add("two folders", base({ find: "draft ", replaceWith: "" }, [item("/a", "draft notes.txt"), item("/b", "draft notes.txt")], { "/a": { names: ["draft notes.txt"], caseSensitive: false }, "/b": { names: ["draft notes.txt", "notes.txt"], caseSensitive: false } }));
  add("unknown folder", base({ mode: "format", nameFormat: "date" }, [item("/elsewhere", "a.jpg"), item("/elsewhere", "b.jpg")], {}));
  add("broken pattern", base({ useRegex: true, find: "[", replaceWith: "" }, [item("/trip", "a.txt")], one("/trip", ["a.txt"])));
  add("numbered back to itself", base({ mode: "format", keepNames: true, separator: " " }, [item("/trip", "File 1 2.jpg")], one("/trip", ["File 1 2.jpg", "File 1 2 1.jpg"])));
  add("root folder", base({ mode: "format" }, [item("", "a.txt"), item("", "b.txt")], { "/": { names: ["a.txt", "b.txt", "File 1.txt"], caseSensitive: false } }));
  add("many wanting one name", base({ useRegex: true, find: "IMG_\\d+", replaceWith: "Lisbon" }, Array.from({ length: 40 }, (_, index) => item("/trip", `IMG_${index}.jpg`)), one("/trip", [...Array.from({ length: 40 }, (_, index) => `IMG_${index}.jpg`), "Lisbon 5.jpg", "Lisbon 12.jpg"])));

  // Random: a few items in one to three folders, whose names hold some of what the items want.
  while (cases.length < 300) {
    const settings = randomSettings(rng);
    settings.onConflict = rng.pick(["number", "number", "skip", "block"]);
    if (rng.chance(0.4)) {
      Object.assign(settings, { mode: "format", nameFormat: rng.pick(["index", "counter", "date"]), customName: rng.pick(["File", "x", "Lisbon"]), separator: rng.pick([" ", "_", ""]), formatWhere: "after", keepNames: false });
    }
    const folderCount = rng.pick([1, 1, 2, 3]);
    const folderPaths = FOLDERS.slice(0, folderCount);
    const folders: Record<string, Folder> = {};
    const items: PlanItem[] = [];
    for (const folder of folderPaths) {
      const itemNames = Array.from(new Set(rng.pickMany(NAMES, rng.int(1, 5))));
      const extra = rng.pickMany(WANTED, rng.int(0, 8));
      const others = rng.pickMany(NAMES, rng.int(0, 3));
      folders[folder] = { names: Array.from(new Set([...itemNames, ...extra, ...others])), caseSensitive: rng.chance(0.3) };
      for (const name of itemNames) {
        items.push({ path: `${folder}/${name}`, ...makeItem(name, rng, rng.chance(0.1)) });
      }
    }
    // Items of the batch in any order.
    for (let index = items.length - 1; index > 0; index--) {
      const other = rng.int(0, index);
      [items[index], items[other]] = [items[other] as PlanItem, items[index] as PlanItem];
    }
    const cannotRename: Record<string, string> = {};
    if (rng.chance(0.15) && items.length > 0) {
      cannotRename[(rng.pick(items) as PlanItem).path] = "The item is locked.";
    }
    if (rng.chance(0.1)) {
      // A folder the plan is not told about.
      delete folders[folderPaths[0] as string];
    }
    add(`random ${String(settings.mode)} ${String(settings.onConflict)}`, { settings: { ...DEFAULTS, ...settings }, items, folders, cannotRename, now: NOW });
  }
  return cases;
}
