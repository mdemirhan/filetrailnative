// Runs an execution scenario through the reference's copy engine in a fresh work folder and
// describes everything that matters about what it did (format in tools/parity/README.md):
// the tree before and after, the ordered event stream (progress, questions with their allowed
// answers and the answer given, journal writes, stops, a crash), the result, the undo log, the
// Trash, the journal file, and after a crash what the app's startup recovery made of it.
// The engine runs in a child Bun process (engine.ts), so a crash can be a real SIGKILL.
// Usage: bun tools/parity/exec/run.ts [--raw] <scenario.json>   (prints the outcome as JSON;
// --raw leaves it as recorded, with the places normalize.ts needs)

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { importReference } from "../lib/reference";
import { type EngineSpec, nextTrashNumber, withTrash } from "./engine";
import { type Place, normalizeOutcome } from "./normalize";
import {
  type Places,
  type Scenario,
  buildTree,
  detachAll,
  makePlaces,
  removePlaces,
  snapshotPlaces,
  snapshotTrash,
} from "./places";
import type { SnapshotEntry } from "./snapshot";

export type { Scenario, ScenarioItem } from "./places";

type Json = Record<string, unknown>;

export type ScenarioOutcome = {
  before: SnapshotEntry[];
  after: SnapshotEntry[];
  trash: SnapshotEntry[];
  // In order: { kind: "event" | "answer" | "journal" | "change" | "stop" | "crash" | "issues" | "error", ... }.
  events: Json[];
  // The paste's result without its undo log; null when it never finished.
  result: Json | null;
  undoLog: unknown;
  // The journal file when the engine was done (or killed); [] when it was never written.
  journal: unknown;
  // After a crash: the startup recovery's report and log, and the tree, Trash and journal after it.
  recovery: {
    notices: string[];
    finished: string[];
    log: Array<{ level: string; message: string; details: unknown }>;
    after: SnapshotEntry[];
    trash: SnapshotEntry[];
    journal: unknown;
  } | null;
};

export type RawOutcome = { places: Place[]; outcome: ScenarioOutcome };

const ENGINE = join(import.meta.dir, "engine.ts");
// As bootstrap.ts gives recovery at startup (RECOVERY_ANSWER_WITHIN_MS).
const RECOVERY_ANSWER_WITHIN_MS = 3000;

type Core = { nativeFileSystem: Record<string, unknown> };
type JournalModule = {
  openWriteJournal: (path: string) => Promise<unknown>;
  recoverWrites: (
    journal: unknown,
    fileSystem: unknown,
    logger: { info: (message: string, details?: unknown) => void; error: (message: string, details?: unknown) => void },
    options: { answerWithinMs: number },
  ) => Promise<{ notices: string[]; finished: string[] }>;
};

function trashPlaces(scenario: Scenario, places: Places): EngineSpec["trash"] {
  if (scenario.trash === false) {
    return null;
  }
  return [
    { mount: "", folder: places.trash },
    ...places.volumes.map((volume) => ({ mount: volume.mount, folder: volume.trash })),
  ];
}

async function readJournal(path: string): Promise<unknown> {
  if (!existsSync(path)) {
    return [];
  }
  return JSON.parse(await readFile(path, "utf8"));
}

function checkAnswers(scenario: Scenario, events: Json[]): void {
  for (const event of events) {
    if (event.kind === "answer" && !(event.allowed as string[]).includes(event.answer as string)) {
      throw new Error(
        `${scenario.name}: answer "${event.answer}" isn't one of ${JSON.stringify(event.allowed)} (the write service would refuse it)`,
      );
    }
  }
}

// Runs the scenario and returns the outcome as recorded, with the places to normalize it by.
export async function runScenarioRaw(scenario: Scenario): Promise<RawOutcome> {
  const places = await makePlaces(scenario);
  try {
    await buildTree(places, scenario.tree);
    const before = await snapshotPlaces(places);
    const trash = trashPlaces(scenario, places);
    const logPath = join(places.work, "engine.log");
    const spec: EngineSpec = {
      mode: scenario.paste.mode,
      sources: scenario.paste.sources.map(places.resolve),
      destination: places.resolve(scenario.paste.destination),
      policy: scenario.policy,
      overrides: scenario.overrides ?? [],
      answers: scenario.answers ?? [],
      stopAfterEvent: scenario.stopAt?.afterEvent ?? null,
      crashAfterJournalWrite: scenario.crashAt?.journalWrite ?? null,
      changes: (scenario.changes ?? []).map((change) => ({
        afterEvent: change.afterEvent ?? null,
        ops: change.ops.map((op) => ({ ...op, path: places.resolve(op.path) })),
      })),
      trash,
      journalPath: places.journal,
      logPath,
    };
    const specPath = join(places.work, "engine.json");
    await writeFile(specPath, JSON.stringify(spec));
    const child = spawnSync(process.execPath, [ENGINE, specPath], { encoding: "utf8" });
    const crashed = child.signal === "SIGKILL";
    if (scenario.crashAt && !crashed) {
      throw new Error(`${scenario.name}: the engine never made journal write ${scenario.crashAt.journalWrite}`);
    }
    if (!crashed && child.status !== 0) {
      throw new Error(`${scenario.name}: the engine failed (${child.status ?? child.signal}): ${child.stderr.slice(-2000)}`);
    }
    const lines = existsSync(logPath) ? (await readFile(logPath, "utf8")).split("\n").filter(Boolean) : [];
    const records = lines.map((line) => JSON.parse(line) as Json);
    const events = records.filter((item) => item.kind !== "result");
    if (crashed) {
      events.push({ kind: "crash", afterJournalWrite: scenario.crashAt?.journalWrite ?? null });
    }
    checkAnswers(scenario, events);
    const finished = records.find((item) => item.kind === "result")?.result as Json | undefined;
    const issues = records.find((item) => item.kind === "issues");
    let result: Json | null = null;
    let undoLog: unknown = null;
    if (finished !== undefined) {
      const { undoLog: log, ...rest } = finished;
      result = rest;
      undoLog = log ?? null;
    } else if (issues !== undefined) {
      result = { issues: issues.issues };
    }
    const outcome: ScenarioOutcome = {
      before,
      after: await snapshotPlaces(places),
      trash: await snapshotTrash(places),
      events,
      result,
      undoLog,
      journal: await readJournal(places.journal),
      recovery: crashed ? await recover(places, trash) : null,
    };
    return { places: places.tokens, outcome };
  } finally {
    await removePlaces(places);
  }
}

// The app's startup recovery (bootstrap.ts: openWriteJournal, then recoverWrites) on the
// journal a crash left, with the same file system and Trash the engine had.
async function recover(places: Places, trash: EngineSpec["trash"]): Promise<ScenarioOutcome["recovery"]> {
  const core = await importReference<Core>("packages/core/src/fs/testNativePaste.ts");
  const module = await importReference<JournalModule>("apps/desktop/src/main/bootstrap/writeJournal.ts");
  const fileSystem = withTrash(core.nativeFileSystem, trash, await nextTrashNumber(trash));
  const log: Array<{ level: string; message: string; details: unknown }> = [];
  const journal = await module.openWriteJournal(places.journal);
  const report = await module.recoverWrites(
    journal,
    fileSystem,
    {
      info: (message, details) => log.push({ level: "info", message, details: plain(details) }),
      error: (message, details) => log.push({ level: "error", message, details: plain(details) }),
    },
    { answerWithinMs: RECOVERY_ANSWER_WITHIN_MS },
  );
  return {
    notices: report.notices,
    finished: report.finished,
    log,
    after: await snapshotPlaces(places),
    trash: await snapshotTrash(places),
    journal: await readJournal(places.journal),
  };
}

// What the recovery logged with a message, as JSON: errors by their message.
function plain(value: unknown): unknown {
  if (value instanceof Error) {
    return value.message;
  }
  if (Array.isArray(value)) {
    return value.map(plain);
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, plain(item)]));
  }
  return value ?? null;
}

export async function runScenario(scenario: Scenario): Promise<ScenarioOutcome> {
  const { places, outcome } = await runScenarioRaw(scenario);
  return normalizeOutcome(outcome, places) as ScenarioOutcome;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const raw = args.includes("--raw");
  const file = args.find((arg) => arg !== "--raw");
  if (file === undefined) {
    console.error("usage: bun tools/parity/exec/run.ts [--raw] <scenario.json>");
    process.exit(2);
  }
  const scenario = JSON.parse(await readFile(file, "utf8")) as Scenario;
  try {
    const output = raw ? await runScenarioRaw(scenario) : await runScenario(scenario);
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
  } finally {
    detachAll();
  }
}
