// getPathSuggestions and resolvePathTarget (packages/core/src/fs/explorerService.ts) on the fixture trees:
// 200 cases of typed paths (existing folders with and without a trailing slash, partial names in either
// case, paths that don't exist, odd spacing and dots), with and without hidden items, under several limits.
// Input: { path, includeHidden, limit } (path relative to the fixtures folder, as typed after it).
// Output: { basePath, suggestions: [{ path, name }], resolved } with paths relative to the fixtures folder.
//
// MACHINE-LOCAL: it reads the fixtures, which --check can't count on being there (the Swift test skips
// without them).

import { readdirSync } from "node:fs";
import { join } from "node:path";

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";
import { fixturesRoot, folders } from "./classify";

export const seed = 0x11570003;
export const machineLocal = true;

type Service = {
  getPathSuggestions: (
    inputPath: string,
    includeHidden: boolean,
    limit: number,
  ) => Promise<{ basePath: string | null; suggestions: Array<{ path: string; name: string; isDirectory: boolean }> }>;
  resolvePathTarget: (path: string) => Promise<{ inputPath: string; resolvedPath: string | null }>;
};

function relative(root: string, value: string | null): string | null {
  if (value === null) {
    return null;
  }
  if (value === root) {
    return "";
  }
  return value.startsWith(`${root}/`) ? value.slice(root.length + 1) : `OUTSIDE:${value}`;
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const service = await importReference<Service>("packages/core/src/fs/explorerService.ts");
  const root = fixturesRoot();
  const directories = ["names", "lighthouse"].flatMap((folder) => folders(root, folder));

  // The typed paths: a pool made from every folder, from which 200 are drawn.
  const typed = new Set<string>();
  for (const directory of directories) {
    typed.add(directory);
    typed.add(`${directory}/`);
    typed.add(`${directory}/nothing-here`);
    typed.add(`${directory}/nothing-here/deeper`);
    typed.add(`${directory}//`);
    typed.add(`${directory}/./`);
    const names = readdirSync(join(root, directory));
    for (const name of names) {
      for (const length of [1, 2, 3]) {
        const prefix = [...name].slice(0, length).join("");
        typed.add(`${directory}/${prefix}`);
        typed.add(`${directory}/${prefix.toUpperCase()}`);
        typed.add(`${directory}/${prefix.toLowerCase()}`);
      }
      typed.add(`${directory}/${name}`);
      typed.add(`${directory}/${name}/`);
    }
  }
  typed.add("names/links/../dots/");
  typed.add("names/links/link to folder/");
  typed.add("names/links/link to folder");
  typed.add("names/links/broken link/");
  typed.add("  names/links/  ");
  typed.add("names/links/ ");
  typed.add("names/spaces/ ");
  typed.add("names/spaces/a ");
  typed.add("names/packages/Sample.app/");
  typed.add("names/packages/Sample.app/Contents/");
  typed.add("names/packages/S");
  typed.add("names/nfd/");
  typed.add("names/nfc/");
  typed.add("names/dots/.");
  typed.add("names/dots/..");
  typed.add("names/dots/..d");
  const pool = [...typed].sort();

  const cases: GoldenCase[] = [];
  const used = new Set<string>();
  while (cases.length < 200 && used.size < pool.length * 8) {
    const path = rng.pick(pool);
    const includeHidden = rng.chance(0.5);
    const limit = rng.pick([1, 2, 3, 12, 12, 12, 50]);
    const name = `${cases.length}: ${JSON.stringify(path)} hidden ${includeHidden} limit ${limit}`;
    const key = `${path}|${includeHidden}|${limit}`;
    if (used.has(key)) {
      continue;
    }
    used.add(key);
    const absolute = `${root}/${path}`;
    const response = await service.getPathSuggestions(absolute, includeHidden, limit);
    const resolved = await service.resolvePathTarget(absolute);
    cases.push({
      name,
      input: { path, includeHidden, limit },
      output: {
        basePath: relative(root, response.basePath),
        suggestions: response.suggestions.map((suggestion) => ({
          path: relative(root, suggestion.path),
          name: suggestion.name,
        })),
        resolved: relative(root, resolved.resolvedPath),
      },
    });
  }
  return cases;
}
