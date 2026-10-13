// The child process run.ts starts for each execution scenario: it pastes through the reference
// engine (packages/core with the native addon, as testNativePaste.ts wires it, plus the app's
// own journal file from apps/desktop's writeJournal.ts) and writes what happens, in order, to a
// log file, one JSON record per line, each written before the engine goes on. It stops the paste
// after a chosen progress event, and kills itself (SIGKILL) right after a chosen journal write:
// a crash at that very point, which run.ts then recovers from.
// Usage: bun tools/parity/exec/engine.ts <spec.json>   (spec: see EngineSpec)

import { closeSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { readdir, rename } from "node:fs/promises";
import { basename } from "node:path";

import { importReference } from "../lib/reference";
import type { ChangeOp } from "./places";

export type EngineSpec = {
  mode: "copy" | "cut";
  sources: string[];
  destination: string;
  policy: Record<string, string>;
  overrides: Array<{ nodeId: string; action: string }>;
  answers: string[];
  stopAfterEvent: number | null;
  crashAfterJournalWrite: number | null;
  // Absolute paths.
  changes: Array<{ afterEvent: number | null; ops: ChangeOp[] }>;
  // null: no Trash. Otherwise each disk's Trash folder, by mount point ("" for the startup disk).
  trash: Array<{ mount: string; folder: string }> | null;
  journalPath: string;
  logPath: string;
};

type Json = Record<string, unknown>;
type FileSystem = Record<string, unknown> & { trash?: (path: string) => Promise<string | null> };

type Core = {
  nativeFileSystem: FileSystem;
};
type Analysis = {
  buildCopyPasteAnalysisReport: (args: Json) => Promise<Json & { issues: unknown[]; analysisId: string }>;
  normalizeCopyPasteAnalysisRequest: (request: Json) => Json;
};
type Policy = { resolveAnalysisWithPolicy: (args: Json) => Promise<unknown[]> };
type Execution = { executeCopyPasteFromAnalysis: (args: Json) => Promise<unknown> };
type Service = { getAllowedRuntimeResolutions: (conflict: Json) => string[] };
type Journal = {
  openWriteJournal: (path: string) => Promise<{
    add: (entry: Json & { id: string }) => Promise<void>;
    remove: (id: string) => Promise<void>;
    entries: () => Array<Json & { id: string }>;
  }>;
};

// The Trash the original's tests give the engine (testNativePaste.ts nativeFileSystemWithTrash):
// a folder items are moved into as "<n>-<name>", here one per disk, numbered across them.
export function withTrash(fileSystem: FileSystem, trash: EngineSpec["trash"], firstNumber: number): FileSystem {
  if (trash === null) {
    return fileSystem;
  }
  let count = firstNumber - 1;
  const folderFor = (path: string) =>
    (trash.find((place) => place.mount !== "" && path.startsWith(`${place.mount}/`)) ??
      trash.find((place) => place.mount === "")) as { folder: string };
  return {
    ...fileSystem,
    trash: async (path: string) => {
      count += 1;
      const inTrash = `${folderFor(path).folder}/${count}-${basename(path)}`;
      await rename(path, inTrash);
      return inTrash;
    },
  };
}

// The next free Trash number: one past the highest in any of the Trash folders.
export async function nextTrashNumber(trash: EngineSpec["trash"]): Promise<number> {
  let highest = 0;
  for (const place of trash ?? []) {
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
  const analysis = await importReference<Analysis>("packages/core/src/fs/copyPasteAnalysis.ts");
  const policy = await importReference<Policy>("packages/core/src/fs/copyPastePolicy.ts");
  const execution = await importReference<Execution>("packages/core/src/fs/copyPasteExecution.ts");
  const service = await importReference<Service>("packages/core/src/fs/writeService.ts");
  const journalModule = await importReference<Journal>("apps/desktop/src/main/bootstrap/writeJournal.ts");

  const fileSystem = withTrash(core.nativeFileSystem, spec.trash, await nextTrashNumber(spec.trash));
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

  const report = await analysis.buildCopyPasteAnalysisReport({
    analysisId: "analysis-test",
    request: analysis.normalizeCopyPasteAnalysisRequest({
      mode: spec.mode,
      sourcePaths: spec.sources,
      destinationDirectoryPath: spec.destination,
    }),
    fileSystem,
    thresholds: { largeBatchItemThreshold: 100_000, largeBatchByteThreshold: 1e12 },
  });
  if (report.issues.length > 0) {
    record({ kind: "issues", issues: report.issues });
    closeSync(log);
    return;
  }
  const resolvedNodes = await policy.resolveAnalysisWithPolicy({
    report,
    policy: spec.policy,
    overrides: spec.overrides,
    fileSystem,
  });
  for (const change of spec.changes.filter((item) => item.afterEvent === null)) {
    applyChange(change.ops);
    record({ kind: "change", ops: change.ops });
  }

  const controller = new AbortController();
  const answers = [...spec.answers];
  let pendingAnswer: Json | null = null;
  let events = 0;
  try {
    await execution.executeCopyPasteFromAnalysis({
      operationId: "op-test",
      report,
      mode: spec.mode,
      policy: spec.policy,
      fileSystem,
      now: () => new Date(),
      signal: controller.signal,
      resolvedNodes,
      writeJournal,
      emit: (event: Json) => {
        const { result, ...rest } = event;
        events += 1;
        record({ kind: "event", ...rest });
        if (pendingAnswer !== null && event.status === "awaiting_resolution") {
          record(pendingAnswer);
          pendingAnswer = null;
        }
        if (result !== null && result !== undefined) {
          record({ kind: "result", result });
        }
        for (const change of spec.changes.filter((item) => item.afterEvent === events)) {
          applyChange(change.ops);
          record({ kind: "change", ops: change.ops });
        }
        if (events === spec.stopAfterEvent) {
          record({ kind: "stop" });
          controller.abort();
        }
      },
      // Asked for just before the question's event goes out (see answerRuntimeConflict).
      requestResolution: async (conflict: Json) => {
        const answer = answers.shift() ?? "skip";
        pendingAnswer = {
          kind: "answer",
          conflictId: conflict.conflictId,
          allowed: service.getAllowedRuntimeResolutions(conflict),
          answer,
        };
        return answer;
      },
    });
  } catch (error) {
    record({ kind: "error", message: error instanceof Error ? error.message : String(error) });
  }
  if (pendingAnswer !== null) {
    record(pendingAnswer);
  }
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
