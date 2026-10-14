// The entries of every folder of fixtures/names and fixtures/lighthouse as the reference explorerService
// classifies them (packages/core/src/fs/explorerService.ts, on the real file system): the snapshot sorted by
// name and by size, the tree children, and the properties of each entry.
// Input: { directory } (relative to the fixtures folder). Output: { byName, bySize, tree, properties }, with
// paths relative to the fixtures folder.
//
// MACHINE-LOCAL: it reads the fixtures, which --check can't count on being there (the Swift test skips
// without them).

import { readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

export const seed = 0x11570002;
export const machineLocal = true;

const FIXTURE_FOLDERS = ["names", "lighthouse"];

type Service = {
  listDirectorySnapshot: (
    path: string,
    includeHidden: boolean,
    sortBy: string,
    sortDirection: string,
    foldersFirst: boolean,
  ) => Promise<{ path: string; entries: Array<Record<string, unknown>> }>;
  listTreeChildren: (
    path: string,
    includeHidden: boolean,
  ) => Promise<{ children: Array<Record<string, unknown>> }>;
  getItemProperties: (path: string) => Promise<{ item: Record<string, unknown> }>;
};

export function fixturesRoot(): string {
  const cache = process.env.FILETRAIL_PORT_CACHE ?? join(homedir(), "Library/Caches/filetrail-port");
  return join(cache, "fixtures");
}

// Every folder under `folder` (symlinks are not followed), `folder` first, in code point order.
export function folders(root: string, folder: string): string[] {
  const found = [folder];
  const names = readdirSync(join(root, folder), { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort((first, second) => (first < second ? -1 : first > second ? 1 : 0));
  for (const name of names) {
    found.push(...folders(root, `${folder}/${name}`));
  }
  return found;
}

function relative(root: string, value: unknown): unknown {
  return typeof value === "string" && value.startsWith(`${root}/`) ? value.slice(root.length + 1) : value;
}

function shown(root: string, entry: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(entry).map(([key, value]) => [key, relative(root, value)]));
}

export async function generate(_rng: Prng): Promise<GoldenCase[]> {
  const service = await importReference<Service>("packages/core/src/fs/explorerService.ts");
  const root = fixturesRoot();
  const cases: GoldenCase[] = [];
  for (const directory of FIXTURE_FOLDERS.flatMap((folder) => folders(root, folder))) {
    const path = join(root, directory);
    const byName = await service.listDirectorySnapshot(path, true, "name", "asc", true);
    const bySize = await service.listDirectorySnapshot(path, true, "size", "desc", true);
    const tree = await service.listTreeChildren(path, true);
    const properties = [];
    for (const entry of byName.entries) {
      const { item } = await service.getItemProperties(entry.path as string);
      // Times and permissions differ from machine to machine.
      const { createdAt: _createdAt, modifiedAt: _modifiedAt, permissionMode: _mode, ...rest } = item;
      properties.push(shown(root, rest));
    }
    cases.push({
      name: directory,
      input: { directory },
      output: {
        byName: byName.entries.map((entry) => shown(root, entry)),
        bySize: bySize.entries.map((entry) => shown(root, entry)),
        tree: tree.children.map((child) => shown(root, child)),
        properties,
      },
    });
  }
  return cases;
}
