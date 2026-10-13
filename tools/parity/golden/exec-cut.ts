// Moves (Cut, then Paste) through the reference engine (tools/parity/exec/run.ts): renames on
// the same disk, per-file moves into a merged folder, Replace, Skip, locks, a move into its own
// folder, and moves to another disk (copy, check, then remove the originals).
// file-operations.md §7 E and F. Input: the scenario. Output: its recorded outcome.

import type { GoldenCase } from "../lib/golden";
import { ADD_MISSING, REPLACE_ALL, SKIP_ALL, dir, execCases, file, link, scenario } from "../exec/scenarios";

export const seed = 0;

const CUT = { mode: "cut" as const, destination: "destination" };

export async function generate(): Promise<GoldenCase[]> {
  return execCases([
    scenario("cut a file on the same disk renames it", [file("source/a.txt"), dir("destination")], {
      ...CUT,
      sources: ["source/a.txt"],
    }),
    scenario(
      "cut a folder on the same disk renames it whole",
      [file("source/f/a.txt"), file("source/f/sub/b.txt"), link("source/f/link", "a.txt"), dir("destination")],
      { ...CUT, sources: ["source/f"] },
    ),
    scenario(
      "cut with Replace on the same disk: the old file to the Trash, the source moved in",
      [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n")],
      { ...CUT, sources: ["source/a.txt"] },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "cut a folder replacing a folder on the same disk",
      [file("source/f/a.txt", "new\n"), file("destination/f/old.txt")],
      { ...CUT, sources: ["source/f"] },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "cut a folder merged into a folder: moved file by file, emptied folders removed",
      [
        file("source/f/new.txt"),
        file("source/f/sub/b.txt"),
        file("source/f/same.txt", "new\n"),
        file("destination/f/same.txt", "old\n"),
        dir("destination/f/sub"),
      ],
      { ...CUT, sources: ["source/f"] },
      { policy: { file: "overwrite", directory: "merge", mismatch: "skip" } },
    ),
    scenario(
      "cut a folder merged with a skipped file: the source folder stays with it",
      [file("source/f/new.txt"), file("source/f/same.txt", "new\n"), file("destination/f/same.txt", "old\n")],
      { ...CUT, sources: ["source/f"] },
      { policy: ADD_MISSING },
    ),
    scenario(
      "cut with Skip leaves the source where it is",
      [file("source/a.txt", "new\n"), file("source/b.txt"), file("destination/a.txt", "old\n")],
      { ...CUT, sources: ["source/a.txt", "source/b.txt"] },
      { policy: SKIP_ALL },
    ),
    scenario(
      "cut a locked file says it is locked",
      [file("source/locked.txt", "locked\n", { flags: ["uchg"] }), file("source/free.txt"), dir("destination")],
      { ...CUT, sources: ["source/locked.txt", "source/free.txt"] },
    ),
    scenario(
      "cut into its own folder is refused",
      [file("folder/a.txt")],
      { mode: "cut", sources: ["folder/a.txt"], destination: "folder" },
    ),
    scenario(
      "cut a file to another disk: copied, then the original removed",
      [file("source/a.txt", "moving\n"), dir("destination")],
      { ...CUT, sources: ["source/a.txt"] },
      { volumes: { destination: "apfs" } },
    ),
    scenario(
      "cut a folder to another disk: built hidden, placed whole, then the originals removed",
      [file("source/f/a.txt"), file("source/f/sub/b.txt"), file("source/f/.hidden"), dir("destination")],
      { ...CUT, sources: ["source/f"] },
      { volumes: { destination: "apfs" } },
    ),
    scenario(
      "cut a folder to another disk with Replace",
      [file("source/f/a.txt", "new\n"), file("destination/f/old.txt"), file("destination/g.txt")],
      { ...CUT, sources: ["source/f"] },
      { policy: REPLACE_ALL, volumes: { destination: "apfs" } },
    ),
    scenario(
      "cut from a FAT32 disk to the startup disk",
      [file("source/a.txt", "from fat\n"), file("source/f/b.txt"), dir("destination")],
      { ...CUT, sources: ["source/a.txt", "source/f"] },
      { volumes: { source: "fat32" } },
    ),
  ]);
}
