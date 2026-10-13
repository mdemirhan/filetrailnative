// The child process run.ts starts for each execution scenario: it pastes through the reference
// app's write service (packages/core's WriteService, as bootstrap.ts makes it: the native file
// system as testNativePaste.ts wires it, the app's Trash wrapper createTrashItem around a
// folder Trash, and the app's own journal file from writeJournal.ts) and writes what happens,
// in order, to a log file, one JSON record per line, each written before the engine goes on.
// Questions are answered as the window does (resolveRuntimeConflict, with "Apply to
// remaining" when the scenario says), the paste is stopped as the Stop button does
// (cancelOperation) after a chosen progress event, and the child kills itself (SIGKILL) right
// after a chosen journal write: a crash at that very point, which run.ts then recovers from.
// Usage: bun tools/parity/exec/engine.ts <spec.json>   (spec: see EngineSpec)

import { chmodSync, closeSync, mkdirSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { readdir, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { basename } from "node:path";

import { importReference } from "../lib/reference";
import type { ChangeOp } from "./places";

// A disk's Trash folder, by mount point ("" for the startup disk), and whether the disk has one.
export type TrashPlace = { mount: string; folder: string; hasTrash: boolean };

export type EngineSpec = {
  mode: "copy" | "cut";
  sources: string[];
  destination: string;
  policy: Record<string, string>;
  overrides: Array<{ nodeId: string; action: string }>;
  answers: string[];
  applyToRemaining: boolean[];
  stopAfterEvent: number | null;
  crashAfterJournalWrite: number | null;
  // Absolute paths.
  changes: Array<{ afterEvent: number | null; ops: ChangeOp[] }>;
  // null: no Trash at all.
  trash: TrashPlace[] | null;
  journalPath: string;
  logPath: string;
};

type Json = Record<string, unknown>;
type FileSystem = Record<string, unknown> & { trash?: (path: string) => Promise<string | null> };

type Core = {
  nativeFileSystem: FileSystem;
};
type Event = Json & { status: string; runtimeConflict: (Json & { conflictId: string }) | null; result: unknown };
type ServiceModule = {
  WriteService: new (dependencies: Json) => {
    subscribe: (listener: (event: Event) => void) => () => void;
    startCopyPasteAnalysis: (request: Json) => { analysisId: string };
    getCopyPasteAnalysisUpdate: (analysisId: string) => {
      done: boolean;
      status: string;
      error: string | null;
      report: (Json & { issues: unknown[] }) | null;
    };
    startCopyPaste: (start: Json) => { operationId: string };
    resolveRuntimeConflict: (operationId: string, conflictId: string, action: string, applyToRemaining: boolean) => { ok: boolean };
    cancelOperation: (operationId: string) => { ok: boolean };
  };
  getAllowedRuntimeResolutions: (conflict: Json) => string[];
};
type Journal = {
  openWriteJournal: (path: string) => Promise<{
    add: (entry: Json & { id: string }) => Promise<void>;
    remove: (id: string) => Promise<void>;
    entries: () => Array<Json & { id: string }>;
  }>;
};
type TrashItemModule = {
  createTrashItem: (args: {
    trash: (path: string) => Promise<string | null>;
    fs: unknown;
    homePath: string;
    diskHasTrash?: (path: string) => boolean;
  }) => (path: string) => Promise<string | null>;
};
type DiskHasTrashModule = {
  createDiskHasTrash: (
    listMounts: () => ReadonlyArray<{ path: string; isLocal: boolean }>,
    realpath: (path: string) => string,
  ) => (path: string) => boolean;
};

const TERMINAL = new Set(["completed", "partial", "failed", "cancelled"]);

// The Trash as bootstrap.ts gives the write service: createTrashItem (which tells a locked
// item, and a disk that may have no Trash, from other failures) around the Trash itself. That
// is a folder per disk items are moved into as "<n>-<name>", numbered across them, as the
// original's tests give the engine (testNativePaste.ts nativeFileSystemWithTrash); on a disk
// without a Trash it fails as the Trash does there, with ENOTSUP.
export async function withTrash(fileSystem: FileSystem, trash: TrashPlace[] | null): Promise<FileSystem> {
  if (trash === null) {
    return fileSystem;
  }
  const { createTrashItem } = await importReference<TrashItemModule>("apps/desktop/src/main/bootstrap/trashItem.ts");
  const { createDiskHasTrash } = await importReference<DiskHasTrashModule>(
    "apps/desktop/src/main/bootstrap/diskHasTrash.ts",
  );
  let count = (await nextTrashNumber(trash)) - 1;
  const placeFor = (path: string) =>
    (trash.find((place) => place.mount !== "" && path.startsWith(`${place.mount}/`)) ??
      trash.find((place) => place.mount === "")) as TrashPlace;
  const folderTrash = async (path: string): Promise<string | null> => {
    const place = placeFor(path);
    if (!place.hasTrash) {
      const message = `“${basename(path)}” couldn’t be moved to the trash because its volume doesn’t have one.`;
      throw Object.assign(new Error(message), { code: "ENOTSUP" });
    }
    count += 1;
    const inTrash = `${place.folder}/${count}-${basename(path)}`;
    await rename(path, inTrash);
    return inTrash;
  };
  // Every disk here is local (a disk image), as listMounts would say.
  const mounts = [
    { path: "/", isLocal: true },
    ...trash.filter((place) => place.mount !== "").map((place) => ({ path: place.mount, isLocal: true })),
  ];
  return {
    ...fileSystem,
    trash: createTrashItem({
      trash: folderTrash,
      fs: fileSystem,
      homePath: homedir(),
      diskHasTrash: createDiskHasTrash(() => mounts, (path) => realpathSync.native(path)),
    }),
  };
}

// The next free Trash number: one past the highest in any of the Trash folders.
async function nextTrashNumber(trash: TrashPlace[]): Promise<number> {
  let highest = 0;
  for (const place of trash) {
    for (const name of await readdir(place.folder).catch(() => [] as string[])) {
      highest = Math.max(highest, Number.parseInt(name, 10) || 0);
    }
  }
  return highest + 1;
}

// Made synchronously, so a change due after an event is on disk before the engine goes on.
export function applyChange(ops: ChangeOp[]): void {
  for (const op of ops) {
    if (op.op === "write") {
      writeFileSync(op.path, op.content);
    } else if (op.op === "mkdir") {
      mkdirSync(op.path, { recursive: true });
    } else if (op.op === "chmod") {
      chmodSync(op.path, Number.parseInt(op.mode, 8));
    } else {
      rmSync(op.path, { recursive: true, force: true });
    }
  }
}

function readJournalFile(path: string): unknown {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

async function main(specPath: string): Promise<void> {
  const spec = JSON.parse(readFileSync(specPath, "utf8")) as EngineSpec;
  const log = openSync(spec.logPath, "a");
  const record = (value: Json) => writeSync(log, `${JSON.stringify(value)}\n`);

  const core = await importReference<Core>("packages/core/src/fs/testNativePaste.ts");
  const serviceModule = await importReference<ServiceModule>("packages/core/src/fs/writeService.ts");
  const journalModule = await importReference<Journal>("apps/desktop/src/main/bootstrap/writeJournal.ts");

  const fileSystem = await withTrash(core.nativeFileSystem, spec.trash);
  const fileJournal = await journalModule.openWriteJournal(spec.journalPath);
  let journalWrites = 0;
  // Each write of the file, recorded as the file then says; the crash comes right after one.
  const wrote = () => {
    journalWrites += 1;
    record({ kind: "journal", write: journalWrites, entries: readJournalFile(spec.journalPath) });
    if (journalWrites === spec.crashAfterJournalWrite) {
      closeSync(log);
      process.kill(process.pid, "SIGKILL");
    }
  };
  const writeJournal = {
    add: async (entry: Json & { id: string }) => {
      await fileJournal.add(entry);
      wrote();
    },
    remove: async (id: string) => {
      const writes = fileJournal.entries().some((entry) => entry.id === id);
      await fileJournal.remove(id);
      if (writes) {
        wrote();
      }
    },
  };

  const service = new serviceModule.WriteService({
    fileSystem,
    writeJournal,
    // No large-batch warnings: they don't change what is pasted.
    largeBatchItemThreshold: 100_000,
    largeBatchByteThreshold: 1e12,
    createOperationId: () => "op-test",
    createAnalysisId: () => "analysis-test",
  });

  // The review.
  const { analysisId } = service.startCopyPasteAnalysis({
    mode: spec.mode,
    sourcePaths: spec.sources,
    destinationDirectoryPath: spec.destination,
  });
  let update = service.getCopyPasteAnalysisUpdate(analysisId);
  while (!update.done) {
    await new Promise((resolve) => setTimeout(resolve, 1));
    update = service.getCopyPasteAnalysisUpdate(analysisId);
  }
  if (update.status !== "complete" || update.report === null) {
    record({ kind: "error", message: update.error ?? `analysis ${update.status}` });
    closeSync(log);
    return;
  }
  if (update.report.issues.length > 0) {
    record({ kind: "issues", issues: update.report.issues });
    closeSync(log);
    return;
  }
  for (const change of spec.changes.filter((item) => item.afterEvent === null)) {
    applyChange(change.ops);
    record({ kind: "change", ops: change.ops });
  }

  // The paste, from the moment it is queued until its last event.
  const answers = [...spec.answers];
  const applyToRemaining = [...spec.applyToRemaining];
  let operationId: string | null = null;
  let events = 0;
  let finish: () => void = () => {};
  const finished = new Promise<void>((resolve) => {
    finish = resolve;
  });
  service.subscribe((event) => {
    const { result, ...rest } = event;
    events += 1;
    record({ kind: "event", ...rest });
    if (result !== null && result !== undefined) {
      record({ kind: "result", result });
    }
    const id = (event.operationId as string | undefined) ?? operationId;
    for (const change of spec.changes.filter((item) => item.afterEvent === events)) {
      applyChange(change.ops);
      record({ kind: "change", ops: change.ops });
    }
    if (events === spec.stopAfterEvent && id !== null) {
      // Stop: a question still open is dropped, unanswered.
      record({ kind: "stop" });
      service.cancelOperation(id);
    } else if (event.status === "awaiting_resolution" && event.runtimeConflict !== null && id !== null) {
      const conflict = event.runtimeConflict;
      const answer = answers.shift() ?? "skip";
      const standing = applyToRemaining.shift() ?? false;
      const allowed = serviceModule.getAllowedRuntimeResolutions(conflict);
      const { ok } = service.resolveRuntimeConflict(id, conflict.conflictId, answer, standing);
      record({ kind: "answer", conflictId: conflict.conflictId, allowed, answer, applyToRemaining: standing });
      if (!ok) {
        // The service refused it, and the question stays open: run.ts reports the scenario.
        service.cancelOperation(id);
      }
    }
    if (TERMINAL.has(event.status)) {
      finish();
    }
  });
  operationId = service.startCopyPaste({ analysisId, policy: spec.policy, overrides: spec.overrides }).operationId;
  await finished;
  // Anything the service does after its last event (it lets the operation go) is done by now.
  await new Promise((resolve) => setTimeout(resolve, 10));
  closeSync(log);
}

if (import.meta.main) {
  const [specPath] = process.argv.slice(2);
  if (specPath === undefined) {
    console.error("usage: bun tools/parity/exec/engine.ts <spec.json>");
    process.exit(2);
  }
  await main(specPath);
}
