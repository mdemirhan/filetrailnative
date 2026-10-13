// A normalized description of a folder's tree, to compare what two engines leave on disk.
// Usage: bun tools/parity/exec/snapshot.ts <root> [out.json]   (stdout without out.json)
// FTTestSupport.TreeSnapshot writes the identical JSON in Swift.

import { createHash } from "node:crypto";
import { createReadStream, writeFileSync } from "node:fs";
import { lstat, readdir, readlink } from "node:fs/promises";

import { importReference } from "../lib/reference";

// Keys in alphabetical order, as TreeSnapshot writes them; optional ones only when they apply.
export type SnapshotEntry = {
  acl: boolean;
  flags: string[];
  kind: "file" | "dir" | "symlink" | "other";
  mode: string;
  path: string;
  sha256?: string;
  size?: number;
  target?: string;
};

type Native = {
  nativeGetFlags: (path: string) => Promise<number>;
  nativeGetAcl: (path: string) => Promise<string | null>;
};

const UF_IMMUTABLE = 0x2;
const UF_HIDDEN = 0x8000;

let nativeModule: Native | null = null;

async function native(): Promise<Native> {
  if (nativeModule === null) {
    const loaded = await importReference<Native & { default?: Native }>("packages/native-fs/index.js");
    nativeModule = loaded.default ?? loaded;
  }
  return nativeModule;
}

function sha256(path: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    createReadStream(path)
      .on("data", (chunk) => hash.update(chunk))
      .on("error", reject)
      .on("end", () => resolve(hash.digest("hex")));
  });
}

async function describe(path: string, relative: string): Promise<SnapshotEntry> {
  const { nativeGetFlags, nativeGetAcl } = await native();
  const stats = await lstat(path);
  const rawFlags = await nativeGetFlags(path);
  const flags = [...(rawFlags & UF_HIDDEN ? ["hidden"] : []), ...(rawFlags & UF_IMMUTABLE ? ["uchg"] : [])];
  const kind = stats.isFile() ? "file" : stats.isDirectory() ? "dir" : stats.isSymbolicLink() ? "symlink" : "other";
  const entry: SnapshotEntry = {
    acl: (await nativeGetAcl(path)) !== null,
    flags,
    kind,
    mode: (stats.mode & 0o7777).toString(8).padStart(4, "0"),
    path: relative.normalize("NFD"),
  };
  if (kind === "file") {
    entry.sha256 = await sha256(path);
  }
  if (kind === "file" || kind === "symlink") {
    entry.size = stats.size;
  }
  if (kind === "symlink") {
    entry.target = await readlink(path);
  }
  return entry;
}

// Every item below `root` (not `root` itself), sorted by path.
export async function snapshotTree(root: string): Promise<SnapshotEntry[]> {
  const entries: SnapshotEntry[] = [];
  const walk = async (relative: string) => {
    const folder = relative === "" ? root : `${root}/${relative}`;
    for (const name of await readdir(folder)) {
      const childRelative = relative === "" ? name : `${relative}/${name}`;
      const entry = await describe(`${root}/${childRelative}`, childRelative);
      entries.push(entry);
      if (entry.kind === "dir") {
        await walk(childRelative);
      }
    }
  };
  await walk("");
  return entries.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

export function snapshotJson(entries: SnapshotEntry[]): string {
  return `${JSON.stringify(entries, null, 2)}\n`;
}

if (import.meta.main) {
  const [root, out] = process.argv.slice(2);
  if (root === undefined) {
    console.error("usage: bun tools/parity/exec/snapshot.ts <root> [out.json]");
    process.exit(2);
  }
  const json = snapshotJson(await snapshotTree(root));
  if (out === undefined) {
    process.stdout.write(json);
  } else {
    writeFileSync(out, json);
  }
}
