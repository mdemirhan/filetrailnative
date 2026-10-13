// The reference's paste analysis (tools/parity/exec/analysis.ts) across disks, on copies of the
// blank disk images (tools/fixtures/disk-images.sh): case-sensitive APFS, HFS+, FAT32 and exFAT
// as source or destination. Case sensitivity per disk, case-variant names landing on a disk that
// can't tell them apart, AppleDouble companions, FAT's empty files, and moves to another disk
// (never renamed whole). file-operations.md §2.6 and §7 A and E.
// Input: the scenario. Output: report, choices, resolution.

import type { GoldenCase } from "../lib/golden";
import type { DiskFormat } from "../exec/places";
import {
  ADD_MISSING,
  KEEP_ALL,
  REPLACE_ALL,
  type Scenario,
  type ScenarioItem,
  analysisCases,
  dir,
  file,
  scenario,
} from "../exec/scenarios";

export const seed = 0;

// The first four bytes of an AppleDouble file.
const APPLE_DOUBLE = "\u0000\u0005\u0016\u0007\u0000\u0002\u0000\u0000";

const onDisk = (
  name: string,
  tree: ScenarioItem[],
  paste: { mode?: "copy" | "cut"; sources: string[]; destination?: string },
  volumes: Record<string, DiskFormat>,
  policy = REPLACE_ALL,
): Scenario =>
  scenario(name, tree, { mode: paste.mode, sources: paste.sources, destination: paste.destination ?? "destination" }, { policy, volumes });

const conflictTree = [
  file("source/a.txt", "new\n"),
  file("source/f/x.txt", "new x\n"),
  file("source/f/n.txt"),
  file("destination/a.txt", "old\n"),
  file("destination/f/x.txt", "old x\n"),
  file("destination/f/only.txt"),
];

const perDisk = (format: DiskFormat): Scenario[] => [
  onDisk(`${format}: a file and a folder into an empty folder`, [file("source/a.txt"), file("source/f/b.txt"), dir("destination")], { sources: ["source/a.txt", "source/f"] }, { destination: format }),
  onDisk(`${format}: conflicts at the destination`, conflictTree, { sources: ["source/a.txt", "source/f"] }, { destination: format }, ADD_MISSING),
  onDisk(`${format}: a name differing in case at the destination`, [file("source/readme.txt"), file("destination/README.txt")], { sources: ["source/readme.txt"] }, { destination: format }, KEEP_ALL),
  onDisk(`${format}: moved from the disk to the startup disk`, conflictTree, { mode: "cut", sources: ["source/a.txt", "source/f"] }, { source: format }),
  onDisk(`${format}: moved within the disk`, [file("source/f/a.txt"), file("source/b.txt"), dir("destination")], { mode: "cut", sources: ["source/f", "source/b.txt"] }, { source: format, destination: format }),
  onDisk(`${format}: copied into its own folder`, [file("folder/a.txt"), file("folder/f/b.txt")], { sources: ["folder/a.txt", "folder/f"], destination: "folder" }, { folder: format }, KEEP_ALL),
];

const cases: Scenario[] = [
  ...(["apfs", "apfs-cs", "hfs", "fat32", "exfat"] as const).flatMap(perDisk),
  onDisk(
    "case-sensitive source: case-variant names in a folder pasted onto a disk that can't tell them apart",
    [file("source/f/Read.txt", "upper\n"), file("source/f/read.txt", "lower\n"), dir("destination")],
    { sources: ["source/f"] },
    { source: "apfs-cs" },
  ),
  onDisk(
    "case-sensitive source: case-variant names pasted onto a case-sensitive disk land side by side",
    [file("source/f/Read.txt", "upper\n"), file("source/f/read.txt", "lower\n"), dir("destination")],
    { sources: ["source/f"] },
    { source: "apfs-cs", destination: "apfs-cs" },
  ),
  onDisk(
    "case-sensitive source: two picks differing in case onto the startup disk",
    [file("source/X.txt"), file("source/x.txt"), dir("destination")],
    { sources: ["source/X.txt", "source/x.txt"] },
    { source: "apfs-cs" },
  ),
  onDisk(
    "case-sensitive destination: Keep Both reserved by exact case",
    [file("source/a.txt"), file("destination/a.txt"), file("destination/A copy.txt")],
    { sources: ["source/a.txt"] },
    { destination: "apfs-cs" },
    KEEP_ALL,
  ),
  onDisk(
    "FAT32 source: AppleDouble companions go with their item, not as items",
    [file("source/f/a.txt"), file("source/f/._a.txt", APPLE_DOUBLE), file("source/f/._orphan", APPLE_DOUBLE), dir("destination")],
    { sources: ["source/f"] },
    { source: "fat32" },
  ),
  onDisk(
    "APFS: an AppleDouble look-alike is an item of its own",
    [file("source/f/a.txt"), file("source/f/._a.txt", APPLE_DOUBLE), dir("destination")],
    { sources: ["source/f"] },
    { source: "apfs" },
  ),
  onDisk(
    "FAT32: empty files over empty files",
    [file("source/e1", ""), file("source/e2", ""), file("destination/e1", ""), file("destination/e2", "")],
    { sources: ["source/e1", "source/e2"] },
    { source: "fat32", destination: "fat32" },
  ),
  onDisk(
    "exFAT: a folder replacing a file moved from the startup disk",
    [file("source/x/in.txt"), file("destination/x")],
    { mode: "cut", sources: ["source/x"] },
    { destination: "exfat" },
  ),
];

export async function generate(): Promise<GoldenCase[]> {
  return analysisCases(cases);
}
