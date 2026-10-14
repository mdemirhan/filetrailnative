// Searches run by the reference's own search runtime (packages/core/src/search/fdSearch.ts) with its bundled fd,
// on the lighthouse fixture and on a small tree made for the purpose (Git folders and ignore files, hidden items,
// packages, links, names with spaces and accents).
// Input: { tree: "lighthouse" | "scratch", entries (scratch only: the tree, in order), root (under the tree, "" for
// its top), query, patternMode, matchScope, recursive, includeHidden, skipGitFolders, skipGitIgnored }.
// Output: { status, truncated, error, items } with the items sorted by path (fd lists in no fixed order), their paths
// starting "$ROOT" (the tree's top) instead of the machine's path.

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference, referenceRoot } from "../lib/reference";

type Entry = { path: string; kind: "file" | "dir" | "symlink"; content?: string; target?: string };
type Request = {
  tree: "lighthouse" | "scratch";
  entries?: Entry[];
  root: string;
  query: string;
  patternMode: "text" | "glob" | "regex";
  matchScope: "name" | "path";
  recursive: boolean;
  includeHidden: boolean;
  skipGitFolders: boolean;
  skipGitIgnored: boolean;
};
type Item = { path: string; parentPath: string } & Record<string, unknown>;
type Update = { status: string; items: Item[]; nextCursor: number; done: boolean; truncated: boolean; error: string | null };
type Runtime = {
  startSearch: (request: Record<string, unknown>) => { jobId: string };
  getUpdate: (jobId: string, cursor: number) => Update;
  close: () => Promise<void>;
};
type FdSearchModule = { FdSearchRuntime: new (fd: string, deps: { spawn: unknown }) => Runtime };

export const seed = 0x5ea4c002;

const SCRATCH: Entry[] = [
  { path: "project", kind: "dir" },
  { path: "project/.git", kind: "dir" },
  { path: "project/.git/config", kind: "file", content: "[core]\n" },
  { path: "project/.git/HEAD", kind: "file", content: "ref: refs/heads/main\n" },
  { path: "project/.gitignore", kind: "file", content: "build/\n*.log\n!keep.log\n" },
  { path: "project/build", kind: "dir" },
  { path: "project/build/output.js", kind: "file", content: "x" },
  { path: "project/debug.log", kind: "file", content: "x" },
  { path: "project/keep.log", kind: "file", content: "x" },
  { path: "project/.env", kind: "file", content: "A=1\n" },
  { path: "project/.hidden", kind: "dir" },
  { path: "project/.hidden/secret.txt", kind: "file", content: "x" },
  { path: "project/src", kind: "dir" },
  { path: "project/src/App.tsx", kind: "file", content: "x" },
  { path: "project/src/app.test.tsx", kind: "file", content: "x" },
  { path: "project/src/lib", kind: "dir" },
  { path: "project/src/lib/utils.ts", kind: "file", content: "x" },
  { path: "project/src/lib/Utils.md", kind: "file", content: "x" },
  { path: "project/README.md", kind: "file", content: "x" },
  { path: "project/Notes.app", kind: "dir" },
  { path: "project/Notes.app/Contents", kind: "dir" },
  { path: "project/Notes.app/Contents/Info.plist", kind: "file", content: "x" },
  { path: "project/report (1).pdf", kind: "file", content: "x" },
  { path: "project/report 2.pdf", kind: "file", content: "x" },
  { path: "project/c++ notes.txt", kind: "file", content: "x" },
  { path: "project/Résumé.pdf", kind: "file", content: "x" },
  { path: "project/日本語.txt", kind: "file", content: "x" },
  { path: "project/link-to-src", kind: "symlink", target: "src" },
  { path: "project/link-to-readme", kind: "symlink", target: "README.md" },
  { path: "project/empty dir", kind: "dir" },
  { path: "project/app.v2", kind: "dir" },
  { path: "project/app.v2/app.ts", kind: "file", content: "x" },
  { path: "project/-xrm", kind: "file", content: "x" },
  { path: "other", kind: "dir" },
  { path: "other/Report.PDF", kind: "file", content: "x" },
  { path: "other/.git", kind: "file", content: "gitdir: ../project/.git\n" },
];

const QUERIES: Array<[string, Request["patternMode"], Request["matchScope"]]> = [
  ["app", "text", "name"], ["App", "text", "name"], ["report", "text", "name"], ["Report", "text", "name"],
  ["(1)", "text", "name"], ["c++", "text", "name"], ["-xrm", "text", "name"], ["src/", "text", "path"],
  ["src/lib", "text", "path"], ["résumé", "text", "name"], ["Résumé", "text", "name"], ["日本", "text", "name"],
  ["\\.tsx?$", "regex", "name"], ["^app", "regex", "name"], ["(", "regex", "name"], ["no(te", "regex", "name"],
  ["src/.*\\.ts$", "regex", "path"], ["[", "regex", "name"], ["*.ts", "glob", "name"], ["*.{ts,tsx}", "glob", "name"],
  ["**/lib/*", "glob", "path"], ["README*", "glob", "name"], ["[", "glob", "name"], [".env", "glob", "name"],
  [".", "text", "name"], ["log", "text", "name"], ["secret", "text", "name"], ["output", "text", "name"],
  ["git", "text", "name"], ["config", "text", "path"], ["link", "text", "name"], ["zzzz-no-such-name", "text", "name"],
];

const CACHE = process.env.FILETRAIL_PORT_CACHE ?? join(homedir(), "Library/Caches/filetrail-port");

function build(top: string, entries: Entry[]) {
  for (const entry of entries) {
    const path = join(top, entry.path);
    if (entry.kind === "dir") {
      mkdirSync(path, { recursive: true });
    } else if (entry.kind === "symlink") {
      symlinkSync(entry.target as string, path);
    } else {
      writeFileSync(path, entry.content ?? "");
    }
  }
}

async function runSearch(module: FdSearchModule, fd: string, top: string, request: Request) {
  const runtime = new module.FdSearchRuntime(fd, { spawn });
  const root = request.root === "" ? top : join(top, request.root);
  try {
    const started = runtime.startSearch({
      rootPath: root,
      query: request.query,
      patternMode: request.patternMode,
      matchScope: request.matchScope,
      recursive: request.recursive,
      includeHidden: request.includeHidden,
      skipGitFolders: request.skipGitFolders,
      skipGitIgnored: request.skipGitIgnored,
    });
    const items: Item[] = [];
    let cursor = 0;
    for (;;) {
      const update = runtime.getUpdate(started.jobId, cursor);
      items.push(...update.items);
      cursor = update.nextCursor;
      if (update.done) {
        const mask = (text: string) => text.split(top).join("$ROOT");
        items.sort((left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0));
        return {
          status: update.status,
          truncated: update.truncated,
          error: update.error === null ? null : mask(update.error),
          items: items.map((item) => JSON.parse(mask(JSON.stringify(item)))),
        };
      }
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
  } finally {
    await runtime.close();
  }
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const module = await importReference<FdSearchModule>("packages/core/src/search/fdSearch.ts");
  const fd = join(referenceRoot(), "apps/desktop/assets/vendor/fd/darwin-arm64/fd");
  const lighthouse = realpathSync(join(CACHE, "fixtures/lighthouse/Lighthouse"));
  const scratch = realpathSync(mkdtempSync(join(tmpdir(), "ft-search-golden-")));
  build(scratch, SCRATCH);
  const cases: GoldenCase[] = [];
  try {
    const add = async (request: Request) => {
      const top = request.tree === "lighthouse" ? lighthouse : scratch;
      const input: Request = request.tree === "scratch" ? { ...request, entries: SCRATCH } : request;
      cases.push({
        name: `${cases.length}: ${request.tree}/${request.root} ${request.patternMode}/${request.matchScope} ${JSON.stringify(request.query)}`,
        input,
        output: await runSearch(module, fd, top, request),
      });
    };
    const base = { recursive: true, includeHidden: false, skipGitFolders: true, skipGitIgnored: false };
    // Every query on the scratch tree with the defaults, then with everything shown, then with Git's ignore files obeyed.
    for (const [query, patternMode, matchScope] of QUERIES) {
      await add({ tree: "scratch", root: "", query, patternMode, matchScope, ...base });
      await add({ tree: "scratch", root: "project", query, patternMode, matchScope, ...base, includeHidden: true, skipGitFolders: false });
      await add({ tree: "scratch", root: "project", query, patternMode, matchScope, ...base, includeHidden: true, skipGitIgnored: true });
    }
    // The options one at a time.
    const some: Array<[string, Request["patternMode"], Request["matchScope"]]> = [["app", "text", "name"], ["s", "text", "path"], ["*", "glob", "name"]];
    for (const [query, patternMode, matchScope] of some) {
      for (const flags of [
        { recursive: false },
        { includeHidden: true },
        { skipGitFolders: false, includeHidden: true },
        { skipGitIgnored: true },
        { skipGitIgnored: true, includeHidden: true, skipGitFolders: false },
        { recursive: false, includeHidden: true },
      ]) {
        await add({ tree: "scratch", root: "project", query, patternMode, matchScope, ...base, ...flags });
      }
    }
    // The lighthouse fixture.
    const lighthouseQueries: Array<[string, Request["patternMode"], Request["matchScope"]]> = [
      ["a", "text", "name"], ["README", "text", "name"], ["readme", "text", "name"], ["tsx", "text", "name"],
      ["node_modules", "text", "path"], ["*.md", "glob", "name"], ["*.png", "glob", "name"], ["\\.(ts|tsx)$", "regex", "name"],
      ["^[A-Z]", "regex", "name"], ["src/", "text", "path"], ["screens", "text", "name"], ["e", "text", "name"],
      ["zzzz-no-such-name", "text", "name"], ["(", "regex", "name"],
    ];
    for (const [query, patternMode, matchScope] of lighthouseQueries) {
      await add({ tree: "lighthouse", root: "", query, patternMode, matchScope, ...base });
      await add({ tree: "lighthouse", root: "", query, patternMode, matchScope, ...base, includeHidden: true });
      await add({ tree: "lighthouse", root: "app/src", query, patternMode, matchScope, ...base, recursive: false });
    }
    // Random combinations of both.
    for (let index = 0; index < 40; index += 1) {
      const [query, patternMode, matchScope] = rng.pick(QUERIES);
      await add({
        tree: "scratch", root: rng.pick(["", "project", "project/src", "other"]), query, patternMode, matchScope,
        recursive: rng.chance(0.6), includeHidden: rng.chance(0.5), skipGitFolders: rng.chance(0.5), skipGitIgnored: rng.chance(0.5),
      });
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  return cases;
}
