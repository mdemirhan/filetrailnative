// Stops through the reference engine (tools/parity/exec/run.ts): the paste is stopped right
// after its n-th progress event (the first is the write service's "queued"), as the Stop
// button does, dropping a question still open. A stopped folder copy leaves nothing, a stopped
// Replace leaves the old item, items not started are reported.
// file-operations.md §3.7 and §7 F. Input: the scenario. Output: its recorded outcome.

import type { GoldenCase } from "../lib/golden";
import { ADD_MISSING, REPLACE_ALL, dir, execCases, file, scenario, write } from "../exec/scenarios";

export const seed = 0;

const INTO = { destination: "destination" };

const folderAndFile = [
  file("source/f/a.txt"),
  file("source/f/b.txt"),
  file("source/f/c.txt"),
  file("source/g.txt"),
  dir("destination"),
];

export async function generate(): Promise<GoldenCase[]> {
  return execCases([
    scenario("stopped as it starts running: nothing is copied", folderAndFile, { sources: ["source/f", "source/g.txt"], ...INTO }, {
      stopAt: { afterEvent: 2 },
    }),
    scenario(
      "stopped inside a folder copy: nothing of the folder is left",
      folderAndFile,
      { sources: ["source/f", "source/g.txt"], ...INTO },
      { stopAt: { afterEvent: 4 } },
    ),
    scenario(
      "stopped between top-level items: the rest is not started",
      [file("source/a.txt"), file("source/b.txt"), file("source/c.txt"), dir("destination")],
      { sources: ["source/a.txt", "source/b.txt", "source/c.txt"], ...INTO },
      { stopAt: { afterEvent: 3 } },
    ),
    scenario(
      "stopped while building a replacement folder: the old folder stays",
      [file("source/f/a.txt", "new\n"), file("source/f/b.txt"), file("destination/f/old.txt")],
      { sources: ["source/f"], ...INTO },
      { policy: REPLACE_ALL, stopAt: { afterEvent: 4 } },
    ),
    scenario(
      "stopped during a move into a merged folder",
      [file("source/f/a.txt"), file("source/f/b.txt"), file("source/f/c.txt"), file("destination/f/old.txt")],
      { mode: "cut", sources: ["source/f"], ...INTO },
      { policy: ADD_MISSING, stopAt: { afterEvent: 3 } },
    ),
    scenario(
      "stopped while a question is open",
      [file("source/a.txt"), file("source/b.txt"), dir("destination")],
      { sources: ["source/a.txt", "source/b.txt"], ...INTO },
      { stopAt: { afterEvent: 3 }, changes: [{ ops: [write("destination/a.txt", "appeared\n")] }] },
    ),
    scenario(
      "stopped as soon as it is queued",
      [file("source/f/a.txt"), file("source/g.txt"), dir("destination")],
      { sources: ["source/f", "source/g.txt"], ...INTO },
      { stopAt: { afterEvent: 1 } },
    ),
  ]);
}
