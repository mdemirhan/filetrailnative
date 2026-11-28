// The parts of scripts/stalls.sh that read and write JSON: the profile a run starts from, the scenario it plays, and
// the summary of the main thread's blocks each run wrote (Sources/FTFoundation/StallLog.swift).
//
//   bun tools/stalls/stalls.ts profile <dir> <folder> <view>
//   bun tools/stalls/stalls.ts scenario <file> <folder>
//   bun tools/stalls/stalls.ts summarize <runs dir> <out file> [<against file>]
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

type View = "icons" | "list" | "compact";
const views: Record<View, { viewMode: string; label: string }> = {
  icons: { viewMode: "icons", label: "Icons 32 pt" },
  list: { viewMode: "details", label: "List, 5 columns" },
  compact: { viewMode: "list", label: "Compact List 160 pt" },
};

/** The smallest sizes, where a screen holds the most items. */
const smallest = {
  iconSizes: { standard: 32, finder: 32 },
  compactListWidths: { standard: 160, finder: 160 },
  detailColumns: {
    modified: true, size: true, kind: true, created: true, added: true, lastOpened: false, permissions: false,
    tags: false,
  },
};

/** One window, maximized, on `folder` in `view` at its smallest size: what a launch into the folder brings back. */
function profile(dir: string, folder: string, view: View) {
  mkdirSync(dir, { recursive: true });
  const preferences = { viewMode: views[view].viewMode, ...smallest };
  const tab = { path: folder, viewMode: views[view].viewMode, viewSizes: smallest };
  const state = {
    preferences,
    windows: [
      { id: "window-stalls", bounds: { width: 1200, height: 800, maximized: true }, session: { openTabs: [tab] } },
    ],
  };
  writeFileSync(join(dir, "app-state.json"), JSON.stringify(state, null, 2) + "\n");
}

/** What each measured step is, by its number in the scenario (from 1). */
type Measured = Record<string, string>;

/**
 * Starts on the folder's parent, goes in for the first time, scrolls down and back, flicks down and back (20,000 points
 * in 0.5 s, about 40 a frame, as fast as a trackpad's flick is at its start), goes out and in again, Back and Forward,
 * types a filter a key at a time as someone reading the list would, then five keys faster than the app draws, and
 * clears it. Each step's time runs until the next step that isn't a wait.
 */
function scenario(file: string, folder: string) {
  const steps: object[] = [];
  const measured: Measured = {};
  const step = (body: object, name?: string) => {
    steps.push(body);
    if (name) measured[String(steps.length)] = name;
  };
  const wait = (ms: number) => step({ step: "wait", ms });
  step({ step: "open", path: dirname(folder) });
  step({ step: "maximize" });
  wait(3000);
  step({ step: "open", path: folder }, "first entry");
  wait(8000);
  step({ step: "scroll", distance: 8000, ms: 2000 }, "scroll down");
  wait(2500);
  step({ step: "scroll", distance: -8000, ms: 2000 });
  wait(1500);
  step({ step: "scroll", distance: 20000, ms: 500 }, "flick down");
  wait(1000);
  step({ step: "scroll", distance: -20000, ms: 500 }, "flick back");
  wait(1500);
  step({ step: "open", path: dirname(folder) });
  wait(2000);
  step({ step: "open", path: folder }, "going back in");
  wait(4000);
  step({ step: "key", key: "[", modifiers: ["cmd"] }, "Back");
  wait(2000);
  step({ step: "key", key: "]", modifiers: ["cmd"] }, "Forward");
  wait(4000);
  for (const key of ["i", "m", "g"]) {
    step({ step: "type", text: key }, "filter key");
    wait(900);
  }
  for (let i = 0; i < 3; i++) {
    step({ step: "key", key: "Backspace", modifiers: [] }, "filter key");
    wait(900);
  }
  step({ step: "type", text: "image", queued: true }, "five keys at once");
  wait(2500);
  step({ step: "key", key: "Escape", modifiers: [] }, "filter cleared");
  wait(1500);
  writeFileSync(file, JSON.stringify({ name: `stalls-${basename(folder)}`, steps, measured }, null, 1) + "\n");
}

// MARK: Summary

type Event = { ev: string; t: number; ms?: number; i?: number; kind?: string; queue?: number };
type Numbers = Record<string, number>;

function readLog(file: string): Event[] {
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

const round = (value: number) => Math.round(value);
const stallsIn = (events: Event[], from: number, to: number) =>
  events.filter((e) => e.ev === "stall" && e.t >= from && e.t < to);

/** Busy, the biggest block, and when the last block of 16 ms or more ended, from `from`. */
function blocks(events: Event[], from: number, to: number, prefix: string, into: Numbers) {
  const stalls = stallsIn(events, from, to);
  into[`${prefix} busy`] = round(stalls.reduce((sum, e) => sum + e.ms!, 0));
  into[`${prefix} biggest block`] = round(Math.max(0, ...stalls.map((e) => e.ms!)));
  const settled = stalls.filter((e) => e.ms! >= 16).map((e) => e.t + e.ms! - from);
  into[`${prefix} settled`] = round(Math.max(0, ...settled));
}

/** The list drawn whole, the first time from `from`. */
function drawn(events: Event[], from: number, to: number): number | undefined {
  const shown = events.find((e) => e.ev === "drawn" && e.t >= from && e.t < to);
  return shown && round(shown.t - from);
}

/** A launch: the process started at 0. */
function launchNumbers(events: Event[]): Numbers {
  const numbers: Numbers = {};
  const end = Math.max(0, ...events.map((e) => e.t)) + 1;
  const at = drawn(events, 0, end);
  if (at !== undefined) numbers["launch: drawn"] = at;
  blocks(events, 0, end, "launch:", numbers);
  return numbers;
}

function navigationNumbers(events: Event[], measured: Measured, report: any): Numbers {
  const numbers: Numbers = {};
  const steps = events.filter((e) => e.ev === "step");
  const end = Math.max(0, ...events.map((e) => e.t)) + 1;
  const kinds = new Map(steps.map((s) => [s.i!, s.kind!]));
  const filterKeys: { busy: number; biggest: number }[] = [];
  for (const [index, name] of Object.entries(measured)) {
    const step = steps.find((s) => s.i === Number(index));
    if (!step) continue;
    const next = steps.find((s) => s.i! > step.i! && kinds.get(s.i!) !== "wait")?.t ?? end;
    if (name === "scroll down" || name === "flick down" || name === "flick back") {
      const message: string = report?.steps?.find((s: any) => s.index === step.i)?.message ?? "";
      const found = message.match(/(\d+) frames: median ([\d.]+) ms.*?(\d+) over/);
      const prefix = name === "scroll down" ? "scroll" : name;
      if (found) {
        numbers[`${prefix}: median frame`] = Number(found[2]);
        numbers[`${prefix}: frames late %`] = round((100 * Number(found[3])) / Number(found[1]));
      }
      continue;
    }
    if (name === "filter key") {
      const stalls = stallsIn(events, step.t, next);
      filterKeys.push({
        busy: stalls.reduce((sum, e) => sum + e.ms!, 0),
        biggest: Math.max(0, ...stalls.map((e) => e.ms!)),
      });
      continue;
    }
    const prefix = `${name}:`;
    const at = drawn(events, step.t, next);
    if (at !== undefined && name !== "five keys at once" && name !== "filter cleared") numbers[`${prefix} drawn`] = at;
    blocks(events, step.t, next, prefix, numbers);
    if (name === "five keys at once" || name === "filter cleared") delete numbers[`${prefix} settled`];
    if (name === "first entry") {
      // The Icons view's own previews: its queue loads 12 at a time.
      const idle = events.filter((e) => e.ev === "previews" && e.queue === 12 && e.t >= step.t && e.t < next);
      if (idle.length) numbers[`${prefix} previews in`] = round(idle[idle.length - 1].t - step.t);
    }
  }
  if (filterKeys.length) {
    numbers["filter key: busy, average"] = round(filterKeys.reduce((s, k) => s + k.busy, 0) / filterKeys.length);
    numbers["filter key: biggest block"] = round(Math.max(...filterKeys.map((k) => k.biggest)));
  }
  return numbers;
}

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
};

type Case = { folder: string; view: string; runs: number; numbers: Numbers };

/** Every run's folder is `<folder name>.<view>.<run>`, holding launch.jsonl, navigation.jsonl, out/report.json. */
function summarize(runsDir: string, out: string, against?: string) {
  const grouped = new Map<string, Numbers[]>();
  for (const run of readdirSync(runsDir).sort()) {
    const dir = join(runsDir, run);
    const parts = run.split(".");
    const view = parts[parts.length - 2];
    const folder = parts.slice(0, -2).join(".");
    const scenarioFile = join(dir, "scenario.json");
    if (!existsSync(scenarioFile)) continue;
    const measured: Measured = JSON.parse(readFileSync(scenarioFile, "utf8")).measured;
    const reportFile = join(dir, "out", "report.json");
    const report = existsSync(reportFile) ? JSON.parse(readFileSync(reportFile, "utf8")) : undefined;
    const failed = (report?.steps ?? []).filter((s: any) => s.status !== "ok");
    for (const step of failed) console.error(`${run}: step ${step.index} (${step.step}) ${step.status}: ${step.message}`);
    const numbers = {
      ...launchNumbers(readLog(join(dir, "launch.jsonl"))),
      ...navigationNumbers(readLog(join(dir, "navigation.jsonl")), measured, report),
    };
    const key = `${folder}\t${view}`;
    grouped.set(key, [...(grouped.get(key) ?? []), numbers]);
  }
  const cases: Case[] = [...grouped].map(([key, runs]) => {
    const [folder, view] = key.split("\t");
    const names = [...new Set(runs.flatMap(Object.keys))];
    const numbers: Numbers = {};
    for (const name of names) {
      const values = runs.map((r) => r[name]).filter((v) => v !== undefined);
      numbers[name] = median(values);
    }
    return { folder, view, runs: runs.length, numbers };
  });
  // Read before the new numbers are written, which may be to the same file.
  const before: Case[] = against ? JSON.parse(readFileSync(against, "utf8")).cases : [];
  writeFileSync(out, JSON.stringify({ cases }, null, 2) + "\n");
  table(cases, before);
}

function table(cases: Case[], before: Case[]) {
  for (const now of cases) {
    const then = before.find((c) => c.folder === now.folder && c.view === now.view);
    const label = views[now.view as View]?.label ?? now.view;
    console.log(`\n${now.folder}, ${label} (median of ${now.runs})`);
    const width = Math.max(...Object.keys(now.numbers).map((n) => n.length));
    const header = then ? `${"".padEnd(width)}  ${"before".padStart(7)}  ${"now".padStart(7)}  change` : "";
    if (header) console.log(header);
    for (const [name, value] of Object.entries(now.numbers)) {
      const unit = name.endsWith("%") ? "" : " ms";
      const old = then?.numbers[name];
      if (old === undefined) {
        console.log(`${name.padEnd(width)}  ${then ? "".padStart(7) + "  " : ""}${String(value).padStart(7)}${unit}`);
        continue;
      }
      const change = old === 0 ? "" : `${value >= old ? "+" : ""}${round((100 * (value - old)) / old)}%`;
      console.log(`${name.padEnd(width)}  ${String(old).padStart(7)}  ${String(value).padStart(7)}${unit}  ${change}`);
    }
  }
}

const [command, ...rest] = process.argv.slice(2);
switch (command) {
  case "profile":
    profile(rest[0], rest[1], rest[2] as View);
    break;
  case "scenario":
    scenario(rest[0], rest[1]);
    break;
  case "summarize":
    summarize(rest[0], rest[1], rest[2]);
    break;
  default:
    console.error("Usage: bun tools/stalls/stalls.ts profile|scenario|summarize …");
    process.exit(1);
}
