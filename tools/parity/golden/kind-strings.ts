// nativeKindForPath (packages/native-fs/src/native_thumbnail.m): the Kind column text of every item in
// fixtures/names and fixtures/lighthouse, and a few system paths, recorded through the reference addon.
// Input: { path } (relative to the fixtures folder, or absolute). Output: the kind string, or null.
//
// MACHINE-LOCAL: Spotlight's kind strings depend on the macOS version, the language and the apps installed,
// so the golden is only valid on the machine that recorded it (the Swift test skips without the fixtures).

import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { referenceRoot } from "../lib/reference";

export const seed = 0x4b1d0004;
export const machineLocal = true;

const FIXTURE_FOLDERS = ["names", "lighthouse"];
const SYSTEM_PATHS = ["/", "/Applications", "/etc/hosts", "/System/Library", "/nonexistent-filetrail-path"];

function fixturesRoot(): string {
  const cache = process.env.FILETRAIL_PORT_CACHE ?? join(homedir(), "Library/Caches/filetrail-port");
  return join(cache, "fixtures");
}

// Every path under `folder` (folders and symlinks are listed, not followed), in code point order.
function walk(root: string, folder: string): string[] {
  const found: string[] = [];
  for (const entry of readdirSync(join(root, folder), { withFileTypes: true })) {
    const path = `${folder}/${entry.name}`;
    found.push(path);
    if (entry.isDirectory()) {
      found.push(...walk(root, path));
    }
  }
  return found;
}

export function generate(_rng: Prng): GoldenCase[] {
  const require = createRequire(import.meta.url);
  const addon = require(join(referenceRoot(), "packages/native-fs/build/Release/native-fs.node")) as {
    nativeKindForPath: (path: string) => string | null;
  };
  const root = fixturesRoot();
  const paths = [...FIXTURE_FOLDERS.flatMap((folder) => [folder, ...walk(root, folder)]), ...SYSTEM_PATHS];
  return paths
    .sort((first, second) => (first < second ? -1 : first > second ? 1 : 0))
    .map((path) => ({
      name: path,
      input: { path },
      output: addon.nativeKindForPath(path.startsWith("/") ? path : join(root, path)),
    }));
}
