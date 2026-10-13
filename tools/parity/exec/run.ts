// Runs an execution scenario through the reference's copy engine (packages/core, with the native
// copy, exclusive rename and lock flags, as testNativePaste.ts wires it) in a fresh temp folder, and
// describes what it did. The scenario format is in tools/parity/README.md.
// Usage: bun tools/parity/exec/run.ts <scenario.json>   (prints the outcome as JSON)

import { chmod, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { importReference } from "../lib/reference";
import { type SnapshotEntry, snapshotTree } from "./snapshot";

export type ScenarioItem =
  | { path: string; kind: "file"; content: string; mode?: string; flags?: string[] }
  | { path: string; kind: "dir"; mode?: string; flags?: string[] }
  | { path: string; kind: "symlink"; target: string };

export type Scenario = {
  name: string;
  tree: ScenarioItem[];
  paste: { mode: "copy" | "cut"; sources: string[]; destination: string };
  policy: { file: string; directory: string; mismatch: string };
  // Answers to the runtime questions, in the order they are asked; "skip" once they run out.
  answers?: string[];
  // Where to stop the paste part way (not supported yet): { "afterEvent": n }.
  stopAt?: { afterEvent: number } | null;
};

export type ScenarioOutcome = {
  before: SnapshotEntry[];
  after: SnapshotEntry[];
  result: unknown;
  questions: unknown[];
  statuses: string[];
};

type NativePaste = {
  runPaste: (args: Record<string, unknown>) => Promise<{
    report: { issues: unknown[] };
    result: Record<string, unknown> | null;
    conflicts: unknown[];
    events: Array<{ status: string }>;
  }>;
  native: { nativeSetFlags: (path: string, flags: number) => Promise<void> };
};

const FLAG_BITS: Record<string, number> = { uchg: 0x2, hidden: 0x8000 };
// Left out of the outcome: they change from run to run.
const UNSTABLE_KEYS = new Set(["startedAt", "finishedAt", "undoLog"]);

async function buildTree(root: string, tree: ScenarioItem[], engine: NativePaste): Promise<void> {
  for (const item of tree) {
    const path = join(root, item.path);
    await mkdir(dirname(path), { recursive: true });
    if (item.kind === "file") {
      await writeFile(path, item.content);
    } else if (item.kind === "dir") {
      await mkdir(path, { recursive: true });
    } else {
      await symlink(item.target, path);
    }
  }
  // Modes and flags last, deepest first, so a read-only or locked folder is filled before.
  for (const item of [...tree].reverse()) {
    if (item.kind === "symlink") {
      continue;
    }
    const path = join(root, item.path);
    await chmod(path, Number.parseInt(item.mode ?? (item.kind === "dir" ? "0755" : "0644"), 8));
    const flags = (item.flags ?? []).reduce((bits, flag) => bits | (FLAG_BITS[flag] ?? 0), 0);
    if (flags !== 0) {
      await engine.native.nativeSetFlags(path, flags);
    }
  }
}

// Paths under the scenario's folder become "$ROOT/..."; unstable keys are dropped.
function normalize(value: unknown, root: string): unknown {
  if (typeof value === "string") {
    return value === root ? "$ROOT" : value.startsWith(`${root}/`) ? `$ROOT${value.slice(root.length)}` : value;
  }
  if (Array.isArray(value)) {
    return value.map((item) => normalize(item, root));
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !UNSTABLE_KEYS.has(key))
        .map(([key, item]) => [key, normalize(item, root)]),
    );
  }
  return value;
}

export async function runScenario(scenario: Scenario): Promise<ScenarioOutcome> {
  if (scenario.stopAt) {
    throw new Error("stopAt is not supported yet");
  }
  const engine = await importReference<NativePaste>("packages/core/src/fs/testNativePaste.ts");
  const root = await realpath(await mkdtemp(join(tmpdir(), "ft-parity-")));
  try {
    await buildTree(root, scenario.tree, engine);
    const before = await snapshotTree(root);
    const answers = [...(scenario.answers ?? [])];
    const run = await engine.runPaste({
      mode: scenario.paste.mode,
      sourcePaths: scenario.paste.sources.map((source) => join(root, source)),
      destinationDirectoryPath: join(root, scenario.paste.destination),
      policy: scenario.policy,
      resolve: () => answers.shift() ?? "skip",
    });
    const after = await snapshotTree(root);
    // Each status once per run of equal ones: progress events come as often as the copy reports.
    const statuses = run.events.map((event) => event.status).filter((status, index, all) => status !== all[index - 1]);
    return {
      before,
      after,
      result: normalize(run.result ?? { issues: run.report.issues }, root),
      questions: normalize(run.conflicts, root) as unknown[],
      statuses,
    };
  } finally {
    await clearFlags(root, engine);
    await rm(root, { recursive: true, force: true });
  }
}

async function clearFlags(root: string, engine: NativePaste): Promise<void> {
  for (const entry of await snapshotTree(root).catch(() => [])) {
    if (entry.flags.length > 0) {
      await engine.native.nativeSetFlags(join(root, entry.path), 0).catch(() => {});
    }
  }
}

if (import.meta.main) {
  const [file] = process.argv.slice(2);
  if (file === undefined) {
    console.error("usage: bun tools/parity/exec/run.ts <scenario.json>");
    process.exit(2);
  }
  const scenario = JSON.parse(await readFile(file, "utf8")) as Scenario;
  process.stdout.write(`${JSON.stringify(await runScenario(scenario), null, 2)}\n`);
}
