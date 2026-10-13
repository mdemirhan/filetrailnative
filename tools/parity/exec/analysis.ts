// Analyzes a scenario's paste through the reference (copyPasteAnalysis.ts, as the write service
// runs it, with its thresholds) in a fresh work folder, and records what the review shows: the
// report (conflict tree, classes, issues, warnings, counts, Keep Both names, blocked Replaces),
// the choices offered for each conflict and what each "For all conflicts" button makes of it,
// and the scenario's policy and overrides resolved into actions (copyPastePolicy.ts).
// Usage: bun tools/parity/exec/analysis.ts <scenario.json>   (prints the normalized outcome)

import { readFile } from "node:fs/promises";

import { importReference } from "../lib/reference";
import { normalizeOutcome } from "./normalize";
import { type Scenario, buildTree, detachAll, makePlaces, removePlaces, snapshotPlaces } from "./places";
import type { SnapshotEntry } from "./snapshot";

type Json = Record<string, unknown>;
type Node = Json & { id: string; conflictClass: string | null; replaceBlockedReason: string | null; children: Node[] };
type Report = Json & { nodes: Node[]; issues: unknown[]; mode: string; summary: Json };
type Resolved = { node: { id: string }; action: string; destinationPath: string; children: Resolved[] };

type AnalysisModule = {
  buildCopyPasteAnalysisReport: (args: Json) => Promise<Report>;
  normalizeCopyPasteAnalysisRequest: (request: Json) => Json;
};
type PolicyModule = { resolveAnalysisWithPolicy: (args: Json) => Promise<Resolved[]> };
type Review = {
  choicesForNode: (node: Node) => string[];
  effectiveChoice: (node: Node, policy: Json, overrides: Record<string, string>) => string | null;
  policyForAllConflicts: (choice: string) => Json;
  allConflictsChoicesFor: (report: Report) => string[];
};
type Core = { nativeFileSystem: Json };

export type AnalysisOutcome = {
  before: SnapshotEntry[];
  report: Report;
  // The "For all conflicts" buttons the review offers.
  allConflictsChoices: string[];
  // For each conflict node, by id: the choices offered, and what each button makes of it.
  choices: Record<string, { offered: string[]; effective: Record<string, string | null> }>;
  // The scenario's policy and overrides resolved; null when the report has issues.
  resolved: unknown;
};

// As the write service analyzes (writeService.ts: 100 items, 1 GiB).
const THRESHOLDS = { largeBatchItemThreshold: 100, largeBatchByteThreshold: 1024 * 1024 * 1024 };
const ALL_CONFLICTS = ["skip", "add_missing", "keep_all", "overwrite"];

function compact(nodes: Resolved[]): unknown[] {
  return nodes.map((node) => ({
    id: node.node.id,
    action: node.action,
    destinationPath: node.destinationPath,
    children: compact(node.children),
  }));
}

function conflictNodes(nodes: Node[]): Node[] {
  return nodes.flatMap((node) => [...(node.conflictClass === null ? [] : [node]), ...conflictNodes(node.children)]);
}

export async function analyzeScenario(scenario: Scenario): Promise<AnalysisOutcome> {
  const analysis = await importReference<AnalysisModule>("packages/core/src/fs/copyPasteAnalysis.ts");
  const policyModule = await importReference<PolicyModule>("packages/core/src/fs/copyPastePolicy.ts");
  const review = await importReference<Review>("apps/desktop/src/renderer/lib/copyPasteReview.ts");
  const { nativeFileSystem } = await importReference<Core>("packages/core/src/fs/testNativePaste.ts");
  const places = await makePlaces(scenario);
  try {
    await buildTree(places, scenario.tree);
    const before = await snapshotPlaces(places);
    const report = await analysis.buildCopyPasteAnalysisReport({
      analysisId: "analysis-test",
      request: analysis.normalizeCopyPasteAnalysisRequest({
        mode: scenario.paste.mode,
        sourcePaths: scenario.paste.sources.map(places.resolve),
        destinationDirectoryPath: places.resolve(scenario.paste.destination),
      }),
      fileSystem: nativeFileSystem,
      thresholds: THRESHOLDS,
    });
    const overrides = Object.fromEntries((scenario.overrides ?? []).map((item) => [item.nodeId, item.action]));
    const choices: AnalysisOutcome["choices"] = {};
    for (const node of conflictNodes(report.nodes)) {
      choices[node.id] = {
        offered: review.choicesForNode(node),
        effective: Object.fromEntries(
          ALL_CONFLICTS.map((button) => [button, review.effectiveChoice(node, review.policyForAllConflicts(button), overrides)]),
        ),
      };
    }
    let resolved: unknown = null;
    if (report.issues.length === 0) {
      try {
        resolved = compact(
          await policyModule.resolveAnalysisWithPolicy({
            report,
            policy: scenario.policy,
            overrides: scenario.overrides ?? [],
            fileSystem: nativeFileSystem,
          }),
        );
      } catch (error) {
        resolved = { error: error instanceof Error ? error.message : String(error) };
      }
    }
    const outcome: AnalysisOutcome = {
      before,
      report,
      allConflictsChoices: review.allConflictsChoicesFor(report),
      choices,
      resolved,
    };
    return normalizeOutcome(outcome, places.tokens) as AnalysisOutcome;
  } finally {
    await removePlaces(places);
  }
}

if (import.meta.main) {
  const [file] = process.argv.slice(2);
  if (file === undefined) {
    console.error("usage: bun tools/parity/exec/analysis.ts <scenario.json>");
    process.exit(2);
  }
  const scenario = JSON.parse(await readFile(file, "utf8")) as Scenario;
  try {
    process.stdout.write(`${JSON.stringify(await analyzeScenario(scenario), null, 2)}\n`);
  } finally {
    detachAll();
  }
}
