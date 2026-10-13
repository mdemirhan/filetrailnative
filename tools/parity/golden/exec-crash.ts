// Crashes through the reference engine (tools/parity/exec/run.ts): the engine process is
// killed (SIGKILL) right after each of its journal writes in turn, then the app's startup
// recovery runs on the same folder. Covers a folder Replace (copy and same-disk move), a file
// Replace, a folder copied whole under a hidden name, and a folder moved to another disk.
// file-operations.md §3.1, §3.5 and §7 J. Input: the scenario. Output: its recorded outcome.

import type { GoldenCase } from "../lib/golden";
import { REPLACE_ALL, crashScenarios, dir, execCases, file, scenario } from "../exec/scenarios";

export const seed = 0;

const INTO = { destination: "destination" };

export async function generate(): Promise<GoldenCase[]> {
  const bases = [
    scenario(
      "folder Replace by copy",
      [file("source/f/a.txt", "new a\n"), file("source/f/sub/b.txt", "new b\n"), file("destination/f/a.txt", "old\n"), file("destination/f/only.txt")],
      { sources: ["source/f"], ...INTO },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "folder Replace by a move on the same disk",
      [file("source/f/a.txt", "new a\n"), file("destination/f/old.txt")],
      { mode: "cut", sources: ["source/f"], ...INTO },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "file Replace by copy",
      [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n")],
      { sources: ["source/a.txt"], ...INTO },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "folder copied whole under a hidden name",
      [file("source/f/a.txt"), file("source/f/sub/b.txt"), dir("destination")],
      { sources: ["source/f"], ...INTO },
    ),
    scenario(
      "folder moved to another disk",
      [file("source/f/a.txt"), file("source/f/b.txt"), dir("destination")],
      { mode: "cut", sources: ["source/f"], ...INTO },
      { volumes: { destination: "apfs" } },
    ),
  ];
  const scenarios = [];
  for (const base of bases) {
    scenarios.push(...(await crashScenarios(base)));
  }
  return execCases(scenarios);
}
