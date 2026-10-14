// listDirectorySnapshot and listTreeChildren (packages/core/src/fs/explorerService.ts) over a fake file system:
// 300 seeded name and kind sets with every sort key, direction and folders-first, giving the order.
// Input: { items: [{ name, type, target?, size, mtimeMs, mode }], includeHidden, sortBy, sortDirection, foldersFirst }
//   type: "dir" | "file" | "link" (target: "dir" | "file" | "missing" | "other") | "unreadable" | "other".
//   A link has the size `linkSize` itself and its target the size `size`.
// Output: { entries: [{ name, extension, kind, isHidden, isSymlink, isExecutable?, sizeBytes? }], tree: [{ name, kind }] }
//   (sizeBytes is null for an entry without one when sorted by size, and left out otherwise).

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

export const seed = 0x11570001;

type Item = {
  name: string;
  type: "dir" | "file" | "link" | "unreadable" | "other";
  target?: "dir" | "file" | "missing" | "other";
  size: number;
  linkSize?: number;
  mtimeMs: number;
  mode: number;
};
type Input = {
  items: Item[];
  includeHidden: boolean;
  sortBy: "name" | "modified" | "kind" | "size";
  sortDirection: "asc" | "desc";
  foldersFirst: boolean;
};

type Service = {
  listDirectorySnapshot: (
    path: string,
    includeHidden: boolean,
    sortBy: string,
    sortDirection: string,
    foldersFirst: boolean,
    fileSystem: unknown,
  ) => Promise<{ entries: Array<Record<string, unknown>> }>;
  listTreeChildren: (
    path: string,
    includeHidden: boolean,
    fileSystem: unknown,
  ) => Promise<{ children: Array<{ name: string; kind: string }> }>;
};

const DIRECTORY = "/golden";

function stats(kind: "dir" | "file" | "link" | "other", size: number, mtimeMs: number, mode: number) {
  return {
    isDirectory: () => kind === "dir",
    isFile: () => kind === "file",
    isSymbolicLink: () => kind === "link",
    birthtime: new Date(1_700_000_000_000),
    mtime: new Date(mtimeMs),
    size,
    mode: kind === "dir" ? 0o755 : mode,
  };
}

function fakeFileSystem(items: Item[]) {
  const byPath = new Map(items.map((item) => [`${DIRECTORY}/${item.name}`, item]));
  return {
    readdir: async () =>
      items.map((item) => ({
        name: item.name,
        isDirectory: () => item.type === "dir",
        isFile: () => item.type === "file" || item.type === "unreadable",
        isSymbolicLink: () => item.type === "link",
      })),
    stat: async (path: string) => {
      if (path === DIRECTORY) {
        return stats("dir", 0, 0, 0o755);
      }
      const item = byPath.get(path);
      if (!item || item.type === "unreadable") {
        throw new Error("unreadable");
      }
      if (item.type === "link") {
        if (item.target === "missing" || item.target === undefined) {
          throw new Error("missing target");
        }
        return stats(item.target, item.size, item.mtimeMs, item.mode);
      }
      return stats(item.type, item.size, item.mtimeMs, item.mode);
    },
    lstat: async (path: string) => {
      const item = byPath.get(path);
      if (!item || item.type === "unreadable") {
        throw new Error("unreadable");
      }
      if (item.type === "link") {
        return stats("link", item.linkSize ?? 0, item.mtimeMs, item.mode);
      }
      return stats(item.type, item.size, item.mtimeMs, item.mode);
    },
    realpath: async (path: string) => path,
  };
}

const NAMES = [
  "Alpha", "alpha", "ALPHA", "beta", "Beta", "gamma.txt", "Gamma.TXT", "delta", "file 2", "file 10", "file 1", "File 02",
  "file 2.txt", "file 10.txt", "file 1.txt", "File 02.TXT", "a", "B", "c", "_under", "-dash", "~tilde", "(paren)", "[bracket]",
  "#hash", "@at", "$dollar", "%pct", "&amp", "+plus", "=eq", ",comma", ";semi", "!bang", "'quote", "x y", "x  y", "x-y", "x_y",
  "x.y", "xy", ".hidden", ".DS_Store", ".gitignore", "..dots", "Makefile", "README", "readme.md", "README.md", "run", "script.sh",
  "Photo 1.jpg", "photo 2.JPG", "photo 10.jpg", "photo 003.jpg", "photo 3.jpg", "report (1).pdf", "report (2).pdf", "report.pdf",
  "Notes.app", "tool.framework", "kit.xcodeproj", "play.playground", "mod.bundle", "plug.plugin", "driver.kext", "svc.xpc",
  "pane.prefpane", "ext.appex", "Safari.APP", ".app", "x.app.txt", "archive.tar.gz", "archive.zip", "data.json", "data.JSON",
  "Résumé.pdf", "resume.pdf", "Resume.pdf", "école", "Ecole", "ecole", "Zebra", "über", "Uber", "naïve", "naive", "Ångström",
  "angstrom", "日本語.txt", "中文", "한국어", "🎉 party", "😀.png", "ǅ", "ﬁle", "file", "straße", "STRASSE", "İstanbul", "istanbul",
  "Æble", "aeble", "ø", "o", "1", "2", "10", "02", "001", "100", "9", "007", "7", "0", "00", "a1", "a01", "a2", "a10", "A1", "1a",
  "12", "1b", "z9", "z10", "Z10", "zz", "a b", "ab", "a_b", "a-b", "A-B", "folder", "Folder", "FOLDER", "src", "Src", "tests",
  "docs", "Docs", "node_modules", "build", "dist", "tmp", "temp", "TEMP", "Untitled", "Untitled 2", "Untitled 10", "untitled folder",
];

const SORT_BY = ["name", "modified", "kind", "size"] as const;
const DIRECTIONS = ["asc", "desc"] as const;
const TIMES = [0, 1_000, 1_700_000_000_000, 1_700_000_000_001, 1_700_000_100_000, 1_800_000_000_000, 946_684_800_000];
const SIZES = [0, 1, 2, 7, 16, 96, 100, 1_000, 4_096, 10_000, 1_000_000, 2_147_483_648];

function randomItem(rng: Prng, name: string): Item {
  const roll = rng.next();
  const type: Item["type"] =
    roll < 0.3 ? "dir" : roll < 0.8 ? "file" : roll < 0.93 ? "link" : roll < 0.97 ? "unreadable" : "other";
  const item: Item = {
    name,
    type,
    size: rng.pick(SIZES),
    mtimeMs: rng.pick(TIMES),
    mode: rng.chance(0.3) ? 0o755 : 0o644,
  };
  if (type === "link") {
    item.target = rng.pick(["dir", "dir", "file", "file", "missing", "other"] as const);
    item.linkSize = rng.pick([7, 16, 24, 40]);
  }
  return item;
}

function entryOf(entry: Record<string, unknown>) {
  const { path: _path, ...rest } = entry;
  return rest;
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const service = await importReference<Service>("packages/core/src/fs/explorerService.ts");
  const cases: GoldenCase[] = [];
  const add = async (label: string, input: Input) => {
    const fileSystem = fakeFileSystem(input.items);
    const snapshot = await service.listDirectorySnapshot(
      DIRECTORY,
      input.includeHidden,
      input.sortBy,
      input.sortDirection,
      input.foldersFirst,
      fileSystem,
    );
    const tree = await service.listTreeChildren(DIRECTORY, input.includeHidden, fileSystem);
    cases.push({
      name: `${cases.length}: ${label}`,
      input,
      output: {
        entries: snapshot.entries.map((entry) => {
          const shown = entryOf(entry);
          // JSON keeps a null size; an absent one is left out.
          return shown;
        }),
        tree: tree.children.map((child) => ({ name: child.name, kind: child.kind })),
      },
    });
  };

  // Every name of the pool once, files only, under every key and direction.
  const everyName: Item[] = NAMES.map((name) => ({ name, type: "file", size: 5, mtimeMs: 1_700_000_000_000, mode: 0o644 }));
  for (const sortBy of SORT_BY) {
    for (const sortDirection of DIRECTIONS) {
      await add(`every name, ${sortBy} ${sortDirection}`, {
        items: everyName,
        includeHidden: true,
        sortBy,
        sortDirection,
        foldersFirst: false,
      });
    }
  }
  // The same names, half of them folders.
  const mixed: Item[] = NAMES.filter((_, position) => position % 2 === 0).map((name, index) => ({
    name,
    type: index % 2 === 0 ? "dir" : "file",
    size: index * 3,
    mtimeMs: TIMES[index % TIMES.length] as number,
    mode: index % 5 === 0 ? 0o755 : 0o644,
  }));
  for (const sortBy of SORT_BY) {
    for (const sortDirection of DIRECTIONS) {
      for (const foldersFirst of [true, false]) {
        await add(`mixed names, ${sortBy} ${sortDirection}, folders first ${foldersFirst}`, {
          items: mixed,
          includeHidden: false,
          sortBy,
          sortDirection,
          foldersFirst,
        });
      }
    }
  }
  // Kinds: one file of each of many extensions.
  const extensions = ["txt", "md", "pdf", "zip", "TXT", "Md", "ts", "tsx", "json", "png", "jpg", "app", "", "x", "z", "a", "B"];
  await add("kinds by extension", {
    items: extensions.map((extension, index) => ({
      name: `file${index}${extension ? `.${extension}` : ""}`,
      type: "file" as const,
      size: index,
      mtimeMs: 1_700_000_000_000,
      mode: 0o644,
    })),
    includeHidden: false,
    sortBy: "kind",
    sortDirection: "asc",
    foldersFirst: true,
  });

  // Random sets.
  while (cases.length < 300) {
    const count = rng.int(0, 40);
    const used = new Set<string>();
    const items: Item[] = [];
    for (let index = 0; index < count; index++) {
      const name = rng.chance(0.15) ? `${rng.pick(NAMES)} ${rng.int(0, 120)}` : rng.pick(NAMES);
      if (used.has(name)) {
        continue;
      }
      used.add(name);
      items.push(randomItem(rng, name));
    }
    await add(`random set of ${items.length}`, {
      items,
      includeHidden: rng.chance(0.5),
      sortBy: rng.pick(SORT_BY),
      sortDirection: rng.pick(DIRECTIONS),
      foldersFirst: rng.chance(0.7),
    });
  }
  return cases;
}
