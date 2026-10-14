// nativeFolderSize (packages/native-fs/src/native_foldersize.c): the sizes, file and folder counts and the
// per-folder breakdown the reference's native walker gives for the shared fixture trees and for generated trees,
// some with folders the walk can't open (counted as folders with nothing in them).
// Input: { kind: "fixture", path } (relative to the fixtures folder), or { kind: "generated", entries } (a tree to
// build, with relative paths and relative link targets so that nothing depends on where it is made).
// Output: { total, diskTotal, fileCount, folderCount, dirs: { <path relative to the root>: [size, disk, files, folders] } }.
//
// MACHINE-LOCAL: disk sizes (allocated blocks) depend on the volume and the files' on-disk state, so the golden is
// only valid on the machine that recorded it (the Swift test skips without the fixtures; gen.sh --check skips it).

import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { referenceRoot } from "../lib/reference";

export const seed = 0x4f51e002;
export const machineLocal = true;

const FIXTURES = ["names", "lighthouse", "bench/files-300", "bench/files-3000"];
const GENERATED_TREES = 4;
const FILE_SIZES = [0, 1, 9, 100, 4095, 4096, 4097, 20_000, 70_000];
const FOLDER_NAMES = ["a", "b", "docs", "Résumé", "two words", ".hidden", "Tool.app", "x\ny"];

type Entry =
  | { path: string; type: "dir" }
  | { path: string; type: "file"; size: number }
  | { path: string; type: "symlink"; target: string }
  // A folder the walk can't open, made unreadable after its contents are in.
  | { path: string; type: "locked"; mode: number };

function fixturesRoot(): string {
  const cache = process.env.FILETRAIL_PORT_CACHE ?? join(homedir(), "Library/Caches/filetrail-port");
  return join(cache, "fixtures");
}

type Native = { nativeFolderSize: (path: string) => Promise<string> };
type Measured = {
  total: number;
  diskTotal: number;
  fileCount: number;
  folderCount: number;
  dirs: Record<string, [number, number, number, number]>;
};

// The reference's walk of `root`, its folders named relative to `root`, in code point order.
async function measure(native: Native, root: string): Promise<unknown> {
  const measured = JSON.parse(await native.nativeFolderSize(root)) as Measured;
  const prefix = root.endsWith("/") ? root : `${root}/`;
  const dirs: Record<string, [number, number, number, number]> = {};
  for (const path of Object.keys(measured.dirs).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))) {
    if (!path.startsWith(prefix)) {
      throw new Error(`${path} is not inside ${root}`);
    }
    dirs[path.slice(prefix.length)] = measured.dirs[path] as [number, number, number, number];
  }
  return {
    total: measured.total,
    diskTotal: measured.diskTotal,
    fileCount: measured.fileCount,
    folderCount: measured.folderCount,
    dirs,
  };
}

// A random tree: folders and files at every depth, links to files and folders (never followed), empty folders,
// and folders the walk can't open, some with folders of their own inside.
function randomEntries(rng: Prng): Entry[] {
  const entries: Entry[] = [];
  const folders: string[] = [];
  const files: string[] = [];
  const makeFolder = (parent: string, depth: number, budget: { left: number }) => {
    const count = rng.int(1, 4);
    for (let index = 0; index < count && budget.left > 0; index++) {
      budget.left -= 1;
      const name = `${rng.pick(FOLDER_NAMES)}-${folders.length}`;
      const path = parent === "" ? name : `${parent}/${name}`;
      entries.push({ path, type: "dir" });
      folders.push(path);
      const fileCount = rng.int(0, 4);
      for (let file = 0; file < fileCount; file++) {
        const filePath = `${path}/f${file}.dat`;
        entries.push({ path: filePath, type: "file", size: rng.pick(FILE_SIZES) });
        files.push(filePath);
      }
      if (depth < 4) {
        makeFolder(path, depth + 1, budget);
      }
    }
  };
  makeFolder("", 0, { left: 60 });
  // Links: relative, so a link's own size doesn't depend on where the tree is.
  for (let link = 0; link < 4; link++) {
    const holder = rng.pick(folders);
    const target = rng.chance(0.5) ? rng.pick(files) : rng.pick(folders);
    const depth = holder.split("/").length;
    entries.push({
      path: `${holder}/link-${link}`,
      type: "symlink",
      target: `${"../".repeat(depth)}${target}`,
    });
  }
  // Folders the walk can't open: with contents, with a folder inside, and empty.
  for (let locked = 0; locked < 3; locked++) {
    const holder = rng.pick(folders);
    const path = `${holder}/locked-${locked}`;
    entries.push({ path, type: "dir" });
    entries.push({ path: `${path}/secret.dat`, type: "file", size: rng.pick(FILE_SIZES) });
    if (locked === 1) {
      entries.push({ path: `${path}/inner`, type: "dir" });
    }
    entries.push({ path, type: "locked", mode: locked === 2 ? 0o100 : 0o000 });
  }
  return entries;
}

// Builds `entries` in `root`, in order, and locks the locked folders last (deepest first).
function build(root: string, entries: Entry[]): { locked: string[] } {
  const locked: string[] = [];
  for (const entry of entries) {
    const path = join(root, entry.path);
    if (entry.type === "dir") {
      mkdirSync(path, { recursive: true });
    } else if (entry.type === "file") {
      writeFileSync(path, "x".repeat(entry.size));
    } else if (entry.type === "symlink") {
      symlinkSync(entry.target, path);
    } else {
      locked.push(entry.path);
    }
  }
  const byDepth = entries
    .filter((entry): entry is Extract<Entry, { type: "locked" }> => entry.type === "locked")
    .sort((a, b) => b.path.split("/").length - a.path.split("/").length);
  for (const entry of byDepth) {
    chmodSync(join(root, entry.path), entry.mode);
  }
  return { locked };
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const require = createRequire(import.meta.url);
  const native = require(join(referenceRoot(), "packages/native-fs/build/Release/native-fs.node")) as Native;
  const cases: GoldenCase[] = [];

  for (const path of FIXTURES) {
    cases.push({
      name: `fixture ${path}`,
      input: { kind: "fixture", path },
      output: await measure(native, join(fixturesRoot(), path)),
    });
  }

  for (let index = 0; index < GENERATED_TREES; index++) {
    const entries = randomEntries(rng);
    const root = mkdtempSync(join(tmpdir(), "ft-golden-sizes-"));
    try {
      const { locked } = build(root, entries);
      cases.push({
        name: `generated tree ${index + 1}`,
        input: { kind: "generated", entries },
        output: await measure(native, root),
      });
      for (const path of locked.sort((a, b) => a.split("/").length - b.split("/").length)) {
        chmodSync(join(root, path), 0o755);
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }
  return cases;
}
