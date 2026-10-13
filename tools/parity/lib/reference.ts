// Loads modules of the reference app (the original Electron/TypeScript File Trail) by path
// from its built clone, so their own imports (@filetrail/contracts, the native-fs addon)
// resolve through the clone's node_modules exactly as in the original's tests.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

export const REPO_ROOT = resolve(import.meta.dir, "../../..");

// The pinned commit of the original, from docs/port/state/orchestrator.json.
export function referenceCommit(): string {
  const state = JSON.parse(readFileSync(join(REPO_ROOT, "docs/port/state/orchestrator.json"), "utf8"));
  const commit = state.referenceCommit;
  if (typeof commit !== "string" || commit.length === 0) {
    throw new Error("no referenceCommit in docs/port/state/orchestrator.json");
  }
  return commit;
}

let checkedRoot: string | null = null;

// The reference clone, checked to be at the pinned commit.
export function referenceRoot(): string {
  if (checkedRoot !== null) {
    return checkedRoot;
  }
  const cache = process.env.FILETRAIL_PORT_CACHE ?? join(homedir(), "Library/Caches/filetrail-port");
  const root = join(cache, "reference/electron");
  const headFile = join(root, ".git/HEAD");
  if (!existsSync(headFile) || !existsSync(join(root, "packages/native-fs/build/Release"))) {
    throw new Error(`no reference build at ${root}: run tools/reference/setup.sh`);
  }
  const head = readFileSync(headFile, "utf8").trim();
  const commit = referenceCommit();
  if (!head.startsWith(commit)) {
    throw new Error(`reference build is at ${head}, pinned ${commit}: run tools/reference/setup.sh`);
  }
  checkedRoot = root;
  return root;
}

// Imports `relativePath` (from the clone's root, e.g. "packages/contracts/src/paths.ts").
export async function importReference<T = Record<string, unknown>>(relativePath: string): Promise<T> {
  return (await import(join(referenceRoot(), relativePath))) as T;
}
