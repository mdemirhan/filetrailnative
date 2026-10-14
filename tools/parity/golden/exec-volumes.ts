// Pastes on each disk image (tools/fixtures/disk-images.sh) through the reference engine
// (tools/parity/exec/run.ts): APFS, case-sensitive APFS, HFS+, FAT32 and exFAT. A copy, a merge
// (Add Missing), Keep Both, Skip, a move within the disk (renamed), and moves onto and off it
// (copied, checked, then the originals removed). file-operations.md §2.6, §3.4 and §7 D and E.
// Input: the scenario. Output: its recorded outcome.

import type { DiskFormat } from "../exec/places";
import type { GoldenCase } from "../lib/golden";
import { ADD_MISSING, SKIP_ALL, type Scenario, dir, execCases, file, scenario } from "../exec/scenarios";

export const seed = 0;

const KEEP_BOTH_ALL = { file: "keep_both", directory: "keep_both", mismatch: "keep_both" };

// What is pasted: a file, an empty file (FAT and exFAT give those no usable id), a hidden file,
// and a folder with a nested folder and an empty one.
const pasted = (top: string) => [
  file(`${top}/a.txt`, "a\n"),
  file(`${top}/empty.txt`, ""),
  file(`${top}/.hidden`, "hidden\n"),
  file(`${top}/f/b.txt`, "b\n"),
  file(`${top}/f/sub/c.txt`, "c\n"),
  dir(`${top}/f/none`),
];
const pastedNames = (top: string) => ["a.txt", "empty.txt", ".hidden", "f"].map((name) => `${top}/${name}`);

// What is already at the destination: a file of the same name, and a folder of the same name
// holding one item of the pasted folder and one of its own.
const existing = [
  file("destination/a.txt", "old a\n"),
  file("destination/f/b.txt", "old b\n"),
  file("destination/f/only.txt", "only\n"),
];

const perDisk = (format: DiskFormat): Scenario[] => [
  scenario(
    `${format}: copied into an empty folder on the disk`,
    [...pasted("source"), dir("destination")],
    { sources: pastedNames("source"), destination: "destination" },
    { volumes: { destination: format } },
  ),
  scenario(
    `${format}: copied off the disk to the startup disk`,
    [...pasted("source"), dir("destination")],
    { sources: pastedNames("source"), destination: "destination" },
    { volumes: { source: format } },
  ),
  scenario(
    `${format}: merged into a folder on the disk with Add Missing`,
    [...pasted("source"), ...existing],
    { sources: pastedNames("source"), destination: "destination" },
    { policy: ADD_MISSING, volumes: { destination: format } },
  ),
  scenario(
    `${format}: kept both on the disk`,
    [...pasted("source"), ...existing],
    { sources: pastedNames("source"), destination: "destination" },
    { policy: KEEP_BOTH_ALL, volumes: { destination: format } },
  ),
  scenario(
    `${format}: skipped on the disk`,
    [...pasted("source"), ...existing],
    { sources: pastedNames("source"), destination: "destination" },
    { policy: SKIP_ALL, volumes: { destination: format } },
  ),
  scenario(
    `${format}: moved within the disk, renamed`,
    [...pasted("source"), dir("destination")],
    { mode: "cut", sources: pastedNames("source"), destination: "destination" },
    { volumes: { source: format, destination: format } },
  ),
  scenario(
    `${format}: moved from the startup disk onto the disk`,
    [...pasted("source"), dir("destination")],
    { mode: "cut", sources: pastedNames("source"), destination: "destination" },
    { volumes: { destination: format } },
  ),
  scenario(
    `${format}: moved off the disk to the startup disk, merged with Add Missing`,
    [...pasted("source"), ...existing],
    { mode: "cut", sources: pastedNames("source"), destination: "destination" },
    { policy: ADD_MISSING, volumes: { source: format } },
  ),
];

export async function generate(): Promise<GoldenCase[]> {
  return execCases((["apfs", "apfs-cs", "hfs", "fat32", "exfat"] as const).flatMap(perDisk));
}
