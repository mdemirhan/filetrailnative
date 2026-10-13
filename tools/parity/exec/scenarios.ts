// Small builders for the scenarios the exec-* and analysis-* golden suites write by hand.

import type { GoldenCase } from "../lib/golden";
import { analyzeScenario } from "./analysis";
import type { ChangeOp, DiskFormat, Scenario, ScenarioItem } from "./places";
import { runScenario, runScenarioRaw } from "./run";

export type { Scenario, ScenarioItem } from "./places";

export const SKIP_ALL = { file: "skip", directory: "skip", mismatch: "skip" };
export const ADD_MISSING = { file: "skip", directory: "merge", mismatch: "skip" };
export const KEEP_ALL = { file: "keep_both", directory: "merge", mismatch: "keep_both" };
export const REPLACE_ALL = { file: "overwrite", directory: "overwrite", mismatch: "overwrite" };

export function file(path: string, content = `${path}\n`, extra: { mode?: string; flags?: string[] } = {}): ScenarioItem {
  return { path, kind: "file", content, ...extra };
}

export function dir(path: string, extra: { mode?: string; flags?: string[] } = {}): ScenarioItem {
  return { path, kind: "dir", ...extra };
}

export function link(path: string, target: string): ScenarioItem {
  return { path, kind: "symlink", target };
}

export function write(path: string, content: string): ChangeOp {
  return { op: "write", path, content };
}

export function remove(path: string): ChangeOp {
  return { op: "remove", path };
}

export function mkdir(path: string): ChangeOp {
  return { op: "mkdir", path };
}

export function chmod(path: string, mode: string): ChangeOp {
  return { op: "chmod", path, mode };
}

// A paste of `sources` into `destination` with every optional field written out, so the
// golden's input says everything the scenario does.
export function scenario(
  name: string,
  tree: ScenarioItem[],
  paste: { mode?: "copy" | "cut"; sources: string[]; destination: string },
  options: Partial<Omit<Scenario, "name" | "tree" | "paste">> & { volumes?: Record<string, DiskFormat> } = {},
): Scenario {
  return {
    name,
    tree,
    paste: { mode: paste.mode ?? "copy", sources: paste.sources, destination: paste.destination },
    policy: options.policy ?? SKIP_ALL,
    overrides: options.overrides ?? [],
    answers: options.answers ?? [],
    applyToRemaining: options.applyToRemaining ?? [],
    stopAt: options.stopAt ?? null,
    crashAt: options.crashAt ?? null,
    changes: options.changes ?? [],
    trash: options.trash ?? true,
    volumes: options.volumes ?? {},
    volumesWithoutTrash: options.volumesWithoutTrash ?? [],
  };
}

export async function execCases(scenarios: Scenario[]): Promise<GoldenCase[]> {
  const cases: GoldenCase[] = [];
  for (const item of scenarios) {
    cases.push({ name: item.name, input: item, output: await runScenario(item) });
  }
  return cases;
}

// The scenario once without a crash, to count its journal writes, then crashed right after
// each of them in turn.
export async function crashScenarios(base: Scenario): Promise<Scenario[]> {
  const { outcome } = await runScenarioRaw(base);
  const writes = outcome.events.filter((event) => event.kind === "journal").length;
  if (writes === 0) {
    throw new Error(`${base.name}: no journal writes to crash after`);
  }
  return Array.from({ length: writes }, (_, index) => ({
    ...base,
    name: `${base.name}, crashed after journal write ${index + 1} of ${writes}`,
    crashAt: { journalWrite: index + 1 },
  }));
}

export async function analysisCases(scenarios: Scenario[]): Promise<GoldenCase[]> {
  const cases: GoldenCase[] = [];
  for (const item of scenarios) {
    cases.push({ name: item.name, input: item, output: await analyzeScenario(item) });
  }
  return cases;
}
