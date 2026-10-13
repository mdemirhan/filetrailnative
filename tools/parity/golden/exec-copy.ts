// Copies through the reference engine (tools/parity/exec/run.ts): plain copies, merges, Keep
// Both, Replace of files and folders, Skip, type mismatches, packages, locks, a disk without a
// Trash, a blocked Replace, an unreadable folder, and copies onto other disks.
// file-operations.md §7 C, D and F. Input: the scenario. Output: its recorded outcome.

import type { GoldenCase } from "../lib/golden";
import {
  ADD_MISSING,
  KEEP_ALL,
  REPLACE_ALL,
  SKIP_ALL,
  chmod,
  dir,
  execCases,
  file,
  link,
  scenario,
} from "../exec/scenarios";

export const seed = 0;

const INTO = { destination: "destination" };

export async function generate(): Promise<GoldenCase[]> {
  return execCases([
    scenario(
      "copy one file into an empty folder",
      [file("source/notes.txt", "File Trail parity\n"), dir("destination")],
      { sources: ["source/notes.txt"], ...INTO },
    ),
    scenario(
      "copy a folder with nested items, hidden ones, an empty folder and links",
      [
        file("source/f/a.txt"),
        file("source/f/.hidden"),
        file("source/f/deep/er/b.txt"),
        dir("source/f/empty"),
        link("source/f/link to a", "a.txt"),
        link("source/f/broken", "nowhere"),
        file("source/f/run.sh", "#!/bin/sh\n", { mode: "0755" }),
        dir("destination"),
      ],
      { sources: ["source/f"], ...INTO },
    ),
    scenario(
      "file conflict skipped",
      [file("source/a.txt", "new\n"), file("source/b.txt"), file("destination/a.txt", "old\n")],
      { sources: ["source/a.txt", "source/b.txt"], ...INTO },
      { policy: SKIP_ALL },
    ),
    scenario(
      "file conflict replaced: the old file goes to the Trash",
      [file("source/a.txt", "new contents\n"), file("destination/a.txt", "old\n")],
      { sources: ["source/a.txt"], ...INTO },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "file conflict kept both: the next free copy name",
      [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n"), file("destination/a copy.txt", "older\n")],
      { sources: ["source/a.txt"], ...INTO },
      { policy: KEEP_ALL },
    ),
    scenario(
      "folder conflict merged with Add Missing: existing files kept",
      [
        file("source/f/a.txt", "new a\n"),
        file("source/f/new.txt"),
        file("source/f/sub/b.txt", "new b\n"),
        file("destination/f/a.txt", "old a\n"),
        file("destination/f/only.txt"),
        file("destination/f/sub/c.txt"),
      ],
      { sources: ["source/f"], ...INTO },
      { policy: ADD_MISSING },
    ),
    scenario(
      "folder conflict merged with files inside replaced",
      [
        file("source/f/a.txt", "new a\n"),
        file("source/f/sub/b.txt", "new b\n"),
        file("destination/f/a.txt", "old a\n"),
        file("destination/f/sub/b.txt", "old b\n"),
        file("destination/f/only.txt"),
      ],
      { sources: ["source/f"], ...INTO },
      { policy: { file: "overwrite", directory: "merge", mismatch: "skip" } },
    ),
    scenario(
      "folder conflict merged with a per-item Keep Both inside",
      [
        file("source/f/a.txt", "new a\n"),
        file("source/f/b.txt", "new b\n"),
        file("destination/f/a.txt", "old a\n"),
        file("destination/f/b.txt", "old b\n"),
      ],
      { sources: ["source/f"], ...INTO },
      { policy: ADD_MISSING, overrides: [{ nodeId: "item-1/b.txt", action: "keep_both" }] },
    ),
    scenario(
      "folder conflict replaced: the old folder and its own items go to the Trash",
      [
        file("source/f/a.txt", "new a\n"),
        file("source/f/sub/b.txt", "new b\n"),
        file("destination/f/a.txt", "old\n"),
        file("destination/f/only.txt"),
      ],
      { sources: ["source/f"], ...INTO },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "type mismatch: a file replaces a folder",
      [file("source/x", "a file\n"), file("destination/x/inside.txt")],
      { sources: ["source/x"], ...INTO },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "type mismatch: a folder replaces a file",
      [file("source/x/inside.txt"), file("destination/x", "a file\n")],
      { sources: ["source/x"], ...INTO },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "type mismatch kept both",
      [file("source/x/inside.txt"), file("destination/x", "a file\n")],
      { sources: ["source/x"], ...INTO },
      { policy: KEEP_ALL },
    ),
    scenario(
      "folder conflict kept both: the whole folder copied as a copy",
      [file("source/f/a.txt"), file("source/f/sub/b.txt"), file("destination/f/a.txt", "old\n")],
      { sources: ["source/f"], ...INTO },
      { policy: { file: "skip", directory: "keep_both", mismatch: "skip" } },
    ),
    scenario(
      "duplicate into its own folder: named a copy, a copy of a copy numbered",
      [file("folder/report.txt"), file("folder/plan copy.md"), file("folder/archive.tar.gz")],
      { sources: ["folder/report.txt", "folder/plan copy.md", "folder/archive.tar.gz"], destination: "folder" },
      { policy: KEEP_ALL },
    ),
    scenario(
      "package conflict replaced whole, never merged",
      [
        file("source/Tool.app/Contents/Info.plist", "<new/>\n"),
        file("source/Tool.app/Contents/MacOS/tool", "new\n"),
        file("destination/Tool.app/Contents/Info.plist", "<old/>\n"),
        file("destination/Tool.app/Contents/Resources/old.png", "png\n"),
      ],
      { sources: ["source/Tool.app"], ...INTO },
      { policy: { file: "overwrite", directory: "merge", mismatch: "skip" } },
    ),
    scenario(
      "a locked file and a read-only folder are copied as they are",
      [
        file("source/locked.txt", "locked\n", { flags: ["uchg"] }),
        file("source/ro/inside.txt"),
        dir("source/ro", { mode: "0555" }),
        file("source/private.txt", "private\n", { mode: "0600" }),
        dir("destination"),
      ],
      { sources: ["source/locked.txt", "source/ro", "source/private.txt"], ...INTO },
    ),
    scenario(
      "Replace on a disk without a Trash, deleted for good once agreed",
      [file("source/a.txt", "new\n"), file("source/f/x.txt"), file("destination/a.txt", "old\n"), file("destination/f/y.txt")],
      { sources: ["source/a.txt", "source/f"], ...INTO },
      { policy: REPLACE_ALL, trash: false, answers: ["overwrite", "overwrite"] },
    ),
    scenario(
      "Replace on a disk without a Trash, skipped: nothing changes",
      [file("source/a.txt", "new\n"), file("source/f/x.txt"), file("destination/a.txt", "old\n"), file("destination/f/y.txt")],
      { sources: ["source/a.txt", "source/f"], ...INTO },
      { policy: REPLACE_ALL, trash: false, answers: ["skip", "skip"] },
    ),
    scenario(
      "Replace for all becomes Merge for the folder holding the item pasted",
      [file("a/f/f/inner.txt"), file("a/f/other.txt")],
      { sources: ["a/f/f"], destination: "a" },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "an unreadable folder fails alone and the rest is pasted",
      [
        file("source/f/ok.txt"),
        file("source/f/closed/secret.txt"),
        dir("source/f/closed", { mode: "0000" }),
        file("source/g.txt"),
        dir("destination"),
      ],
      { sources: ["source/f", "source/g.txt"], ...INTO },
    ),
    scenario(
      "symlink conflict replaced by the link itself",
      [link("source/link", "new-target"), link("destination/link", "old-target")],
      { sources: ["source/link"], ...INTO },
      { policy: REPLACE_ALL },
    ),
    scenario(
      "copy onto a FAT32 disk",
      [file("source/f/a.txt"), file("source/b.txt"), dir("destination")],
      { sources: ["source/f", "source/b.txt"], ...INTO },
      { volumes: { destination: "fat32" } },
    ),
    scenario(
      "copy onto a case-sensitive disk: names differing in case land side by side",
      [file("source/readme.txt", "lower\n"), file("destination/README.txt", "upper\n")],
      { sources: ["source/readme.txt"], ...INTO },
      { volumes: { destination: "apfs-cs" } },
    ),
    scenario(
      "folder replaced on an HFS+ disk",
      [file("source/f/a.txt", "new\n"), file("destination/f/old.txt")],
      { sources: ["source/f"], ...INTO },
      { policy: REPLACE_ALL, volumes: { destination: "hfs" } },
    ),
    // The app's Trash (createTrashItem) on a disk that has none: "may not have a Trash", so the
    // Replace asks before deleting for good.
    scenario(
      "Replace on another disk without a Trash, deleted for good once agreed",
      [file("source/a.txt", "new\n"), file("source/f/x.txt"), file("destination/a.txt", "old\n"), file("destination/f/y.txt")],
      { sources: ["source/a.txt", "source/f"], ...INTO },
      { policy: REPLACE_ALL, answers: ["overwrite", "overwrite"], volumes: { destination: "apfs" }, volumesWithoutTrash: ["destination"] },
    ),
    scenario(
      "Replace on a FAT32 disk without a Trash, skipped: nothing changes",
      [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n")],
      { sources: ["source/a.txt"], ...INTO },
      { policy: REPLACE_ALL, answers: ["skip"], volumes: { destination: "fat32" }, volumesWithoutTrash: ["destination"] },
    ),
    scenario(
      "Replace on a disk without a Trash, deleted for good for the rest: the second isn't asked",
      [file("source/a.txt", "new a\n"), file("source/b.txt", "new b\n"), file("destination/a.txt"), file("destination/b.txt")],
      { sources: ["source/a.txt", "source/b.txt"], ...INTO },
      {
        policy: REPLACE_ALL,
        answers: ["overwrite"],
        applyToRemaining: [true],
        volumes: { destination: "exfat" },
        volumesWithoutTrash: ["destination"],
      },
    ),
    scenario(
      "a locked item on another disk can't go to the Trash: the Replace fails, saying it is locked",
      [file("source/a.txt", "new\n"), file("destination/a.txt", "old\n", { flags: ["uchg"] })],
      { sources: ["source/a.txt"], ...INTO },
      { policy: REPLACE_ALL, volumes: { destination: "apfs" } },
    ),
    // Thrown before any item is started (Keep Both finds no free name in a folder it can't
    // look in): the write service's own "failed" event and result.
    scenario(
      "the destination can't be looked in after the review, Keep Both: the paste fails as a whole",
      [file("source/a.txt"), file("destination/a.txt")],
      { sources: ["source/a.txt"], ...INTO },
      { policy: KEEP_ALL, changes: [{ ops: [chmod("destination", "0000")] }] },
    ),
  ]);
}
