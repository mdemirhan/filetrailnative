// Where a scenario runs: a fresh work folder holding the scenario's tree, a Trash folder and
// the journal file, plus, for top-level folders the scenario puts on another disk, a tree and a
// Trash on a mounted copy of one of the blank disk images (tools/fixtures/disk-images.sh).
// FTTestSupport.ExecPlaces makes the same layout in Swift.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, lstat, mkdir, mkdtemp, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { importReference } from "../lib/reference";
import type { Place } from "./normalize";
import { type SnapshotEntry, snapshotTree } from "./snapshot";

export type DiskFormat = "apfs" | "apfs-cs" | "hfs" | "fat32" | "exfat";

export type ScenarioItem =
  | { path: string; kind: "file"; content: string; mode?: string; flags?: string[] }
  | { path: string; kind: "dir"; mode?: string; flags?: string[] }
  | { path: string; kind: "symlink"; target: string };

export type ChangeOp =
  | { op: "write"; path: string; content: string }
  | { op: "mkdir"; path: string }
  | { op: "remove"; path: string };

export type Scenario = {
  name: string;
  tree: ScenarioItem[];
  paste: { mode: "copy" | "cut"; sources: string[]; destination: string };
  policy: { file: string; directory: string; mismatch: string };
  // Per-item choices from the review, by analysis node id ("item-1/sub/a.txt").
  overrides?: Array<{ nodeId: string; action: string }>;
  // Answers to the runtime questions, in the order they are asked; "skip" once they run out.
  answers?: string[];
  // Stop the paste right after its n-th progress event, as the Stop button does.
  stopAt?: { afterEvent: number } | null;
  // Kill the engine right after its n-th write of the journal file, then run recovery.
  crashAt?: { journalWrite: number } | null;
  // Changes made on disk while the paste runs: after the review (no `afterEvent`) or right
  // after the n-th progress event.
  changes?: Array<{ afterEvent?: number; ops: ChangeOp[] }>;
  // false: the disk has no Trash (a Replace asks before deleting for good).
  trash?: boolean;
  // Top-level folders made on a disk image of their own instead: { "destination": "fat32" }.
  volumes?: Record<string, DiskFormat>;
};

export type Places = {
  work: string;
  // The scenario's tree on the startup disk ("$ROOT").
  root: string;
  // Its Trash ("$TRASH").
  trash: string;
  journal: string;
  // For each folder on a disk image: where its tree and its Trash are, and the mount.
  volumes: Array<{ folder: string; format: DiskFormat; mount: string; root: string; trash: string }>;
  // Absolute path of a scenario-relative path.
  resolve: (relative: string) => string;
  // The Trash folder for an item at an absolute path (its disk's).
  trashFor: (path: string) => string;
  // For normalize.ts: each place and its token.
  tokens: Place[];
};

const FLAG_BITS: Record<string, number> = { uchg: 0x2, hidden: 0x8000 };

type Native = { nativeSetFlags: (path: string, flags: number) => Promise<void> };

let native: Native | null = null;

async function nativeFs(): Promise<Native> {
  if (native === null) {
    const loaded = await importReference<Native & { default?: Native }>("packages/native-fs/index.js");
    native = loaded.default ?? loaded;
  }
  return native;
}

// --- Disk images -----------------------------------------------------------------------------

const mounts = new Map<DiskFormat, string>();
const attached: string[] = [];
let imageFolder: string | null = null;

function cacheRoot(): string {
  return process.env.FILETRAIL_PORT_CACHE ?? join(homedir(), "Library/Caches/filetrail-port");
}

// A copy-on-write clone of the blank image, attached once per process, detached at exit.
export async function mountedVolume(format: DiskFormat): Promise<string> {
  const known = mounts.get(format);
  if (known !== undefined) {
    return known;
  }
  const blank = join(cacheRoot(), "fixtures/disks", `${format}.sparseimage`);
  if (!existsSync(blank)) {
    throw new Error(`no ${blank}: run tools/fixtures/disk-images.sh`);
  }
  if (imageFolder === null) {
    imageFolder = await realpath(await mkdtemp(join(tmpdir(), "ft-parity-disks-")));
    process.on("exit", detachAll);
  }
  const image = join(imageFolder, `${format}.sparseimage`);
  const mount = join(imageFolder, format);
  run("cp", ["-c", blank, image]);
  await mkdir(mount);
  run("hdiutil", ["attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mount, image]);
  attached.push(mount);
  mounts.set(format, mount);
  return mount;
}

export function detachAll(): void {
  while (attached.length > 0) {
    const mount = attached.pop() as string;
    spawnSync("hdiutil", ["detach", "-force", mount], { stdio: "ignore" });
  }
  mounts.clear();
  if (imageFolder !== null) {
    spawnSync("rm", ["-rf", imageFolder], { stdio: "ignore" });
    imageFolder = null;
  }
}

function run(command: string, args: string[]): void {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed: ${result.stderr.trim()}`);
  }
}

// --- Work folders ----------------------------------------------------------------------------

let scenarioCount = 0;

export async function makePlaces(scenario: Scenario): Promise<Places> {
  const work = await realpath(await mkdtemp(join(tmpdir(), "ft-parity-")));
  const root = join(work, "tree");
  const trash = join(work, "trash");
  await mkdir(root);
  await mkdir(trash);
  await mkdir(join(work, "journal"));
  const volumes: Places["volumes"] = [];
  for (const [folder, format] of Object.entries(scenario.volumes ?? {}).sort(([a], [b]) => (a < b ? -1 : 1))) {
    const mount = await mountedVolume(format);
    scenarioCount += 1;
    const base = join(mount, `scenario-${process.pid}-${scenarioCount}`);
    await mkdir(join(base, "tree"), { recursive: true });
    await mkdir(join(base, "trash"));
    volumes.push({ folder, format, mount, root: join(base, "tree"), trash: join(base, "trash") });
  }
  const volumeOf = (relative: string) => volumes.find((volume) => relative.split("/")[0] === volume.folder);
  return {
    work,
    root,
    trash,
    journal: join(work, "journal", "replace-journal.json"),
    volumes,
    resolve: (relative) => join(volumeOf(relative)?.root ?? root, relative),
    trashFor: (path) => volumes.find((volume) => path.startsWith(`${volume.mount}/`))?.trash ?? trash,
    tokens: [
      { path: root, token: "$ROOT" },
      { path: trash, token: "$TRASH" },
      { path: join(work, "journal"), token: "$JOURNAL" },
      ...volumes.flatMap((volume) => [
        { path: volume.root, token: "$ROOT" },
        { path: volume.trash, token: "$TRASH" },
      ]),
    ],
  };
}

// Makes the scenario's tree: items in order, then modes and flags deepest first (the most path
// components first; equally deep ones last item first), so a read-only or locked folder is filled
// before it is closed.
export async function buildTree(places: Places, tree: ScenarioItem[]): Promise<void> {
  const { nativeSetFlags } = await nativeFs();
  for (const item of tree) {
    const path = places.resolve(item.path);
    await mkdir(dirname(path), { recursive: true });
    if (item.kind === "file") {
      await writeFile(path, item.content);
    } else if (item.kind === "dir") {
      await mkdir(path, { recursive: true });
    } else {
      await symlink(item.target, path);
    }
  }
  const depth = (item: ScenarioItem) => item.path.split("/").length;
  for (const item of [...tree].reverse().sort((a, b) => depth(b) - depth(a))) {
    if (item.kind === "symlink") {
      continue;
    }
    const path = places.resolve(item.path);
    await chmod(path, Number.parseInt(item.mode ?? (item.kind === "dir" ? "0755" : "0644"), 8));
    const flags = (item.flags ?? []).reduce((bits, flag) => bits | (FLAG_BITS[flag] ?? 0), 0);
    if (flags !== 0) {
      await nativeSetFlags(path, flags);
    }
  }
}

// What the scenario's tree holds now, wherever its folders are.
export async function snapshotPlaces(places: Places): Promise<SnapshotEntry[]> {
  return snapshotAll([places.root, ...places.volumes.map((volume) => volume.root)]);
}

// What the Trash folders hold now.
export async function snapshotTrash(places: Places): Promise<SnapshotEntry[]> {
  return snapshotAll([places.trash, ...places.volumes.map((volume) => volume.trash)]);
}

// Snapshots of several roots, merged and sorted. Folders the owner can't list and files the
// owner can't read are opened for the snapshot (u+rx, u+r) and closed again after, and keep
// their own mode in it.
async function snapshotAll(roots: string[]): Promise<SnapshotEntry[]> {
  const entries: SnapshotEntry[] = [];
  for (const root of roots) {
    const opened = await openForSnapshot(root, "");
    try {
      const modes = new Map(opened.map((item) => [item.relative.normalize("NFD"), item.mode]));
      for (const entry of await snapshotTree(root)) {
        const mode = modes.get(entry.path);
        entries.push(mode === undefined ? entry : { ...entry, mode: mode.toString(8).padStart(4, "0") });
      }
    } finally {
      for (const item of opened.reverse()) {
        await chmod(join(root, item.relative), item.mode).catch(() => {});
      }
    }
  }
  return entries.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

async function openForSnapshot(root: string, relative: string): Promise<Array<{ relative: string; mode: number }>> {
  const opened: Array<{ relative: string; mode: number }> = [];
  for (const name of await readdir(relative === "" ? root : join(root, relative))) {
    const childRelative = relative === "" ? name : `${relative}/${name}`;
    const path = join(root, childRelative);
    const stats = await lstat(path);
    const mode = stats.mode & 0o7777;
    const needed = stats.isDirectory() ? 0o500 : stats.isFile() ? 0o400 : 0;
    if ((mode & needed) !== needed) {
      await chmod(path, mode | needed);
      opened.push({ relative: childRelative, mode });
    }
    if (stats.isDirectory()) {
      opened.push(...(await openForSnapshot(root, childRelative)));
    }
  }
  return opened;
}

// Clears locks, opens every folder to its owner, and removes the work folder and the
// scenario's folders on disk images.
export async function removePlaces(places: Places): Promise<void> {
  const { nativeSetFlags } = await nativeFs();
  const open = async (path: string): Promise<void> => {
    const stats = await lstat(path).catch(() => null);
    if (stats === null) {
      return;
    }
    await nativeSetFlags(path, 0).catch(() => {});
    if (stats.isDirectory()) {
      await chmod(path, (stats.mode & 0o7777) | 0o700).catch(() => {});
      for (const name of await readdir(path).catch(() => [])) {
        await open(join(path, name));
      }
    }
  };
  for (const folder of [places.work, ...places.volumes.map((volume) => dirname(volume.root))]) {
    await open(folder);
    await rm(folder, { recursive: true, force: true });
  }
}
