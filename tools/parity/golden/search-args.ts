// The fd argument list of a search (packages/core/src/search/fdSearch.ts, buildFdSearchArgs): every combination of
// the options, for the roots and queries that change the answer.
// Input: a search:start request. Output: the argument list.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Request = {
  rootPath: string;
  query: string;
  patternMode: "text" | "glob" | "regex";
  matchScope: "name" | "path";
  recursive: boolean;
  includeHidden: boolean;
  skipGitFolders: boolean;
  skipGitIgnored: boolean;
};
type FdSearchModule = { buildFdSearchArgs: (request: Request) => string[] };

export const seed = 0x5ea4c001;

const ROOTS = ["/", "/Users/demo/project", "/Volumes/Backup", "/Volumes", "/Users/demo/Volumes", "/Users/demo/é ü", "//"];
const QUERIES = ["report", "-xrm", "report (1).pdf", "*.ts", "src/*.ts", "c++", "--exec", "", " ", "日本語", "a b", "-"];
const BOOLEANS = [false, true];
const MODES = ["text", "glob", "regex"] as const;
const SCOPES = ["name", "path"] as const;

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const module = await importReference<FdSearchModule>("packages/core/src/search/fdSearch.ts");
  const cases: GoldenCase[] = [];
  const add = (request: Request) => {
    cases.push({
      name: `${cases.length}: ${request.patternMode}/${request.matchScope} ${JSON.stringify(request.query)} at ${request.rootPath}`,
      input: request,
      output: module.buildFdSearchArgs(request),
    });
  };
  // Every combination of the options, at a plain root with a plain query.
  for (const patternMode of MODES) {
    for (const matchScope of SCOPES) {
      for (const recursive of BOOLEANS) {
        for (const includeHidden of BOOLEANS) {
          for (const skipGitFolders of BOOLEANS) {
            for (const skipGitIgnored of BOOLEANS) {
              add({ rootPath: "/Users/demo/project", query: "report", patternMode, matchScope, recursive, includeHidden, skipGitFolders, skipGitIgnored });
            }
          }
        }
      }
    }
  }
  // Every root and query, with the options the documented defaults give, and with all of them on.
  for (const rootPath of ROOTS) {
    for (const query of QUERIES) {
      add({ rootPath, query, patternMode: "text", matchScope: "name", recursive: true, includeHidden: false, skipGitFolders: true, skipGitIgnored: false });
      add({ rootPath, query, patternMode: "regex", matchScope: "path", recursive: false, includeHidden: true, skipGitFolders: false, skipGitIgnored: true });
    }
  }
  // Random ones.
  for (let index = 0; index < 150; index += 1) {
    add({
      rootPath: ROOTS[rng.int(0, ROOTS.length - 1)] as string,
      query: QUERIES[rng.int(0, QUERIES.length - 1)] as string,
      patternMode: MODES[rng.int(0, 2)] as Request["patternMode"],
      matchScope: SCOPES[rng.int(0, 1)] as Request["matchScope"],
      recursive: rng.chance(0.5),
      includeHidden: rng.chance(0.5),
      skipGitFolders: rng.chance(0.5),
      skipGitIgnored: rng.chance(0.5),
    });
  }
  return cases;
}
