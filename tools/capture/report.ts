// Compares the two sides of a capture and writes the contact sheet. Used by tools/capture/run.sh.
//
//   bun tools/capture/report.ts compare --scenario <file> --a <dir> --b <dir> --out <dir>
//       [--elements <file>] [--pixeldiff <binary>] [--label-a electron] [--label-b swift]
//     Geometry diff (±1 pt frames; exact font size, weight and color) and pixel diff of every
//     snapshot and geometry dump the two sides share. Writes <out>/summary.json and prints one line.
//   bun tools/capture/report.ts contact --out <dir>
//     Writes <dir>/contact.html from every <dir>/<scenario>/diff/summary.json.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";

export interface Frame {
  x: number;
  y: number;
  width: number;
  height: number;
}
export interface Text {
  string: string;
  fontSize?: number;
  fontWeight?: number;
  color?: string;
}
export interface Element {
  id: string;
  frame: Frame;
  text?: Text;
}
export interface Dump {
  format: string;
  side: string;
  name: string;
  window: { width: number; height: number };
  /// The ids the capture looked for (the original's driver writes it; the native app doesn't).
  captured?: string[];
  elements: Element[];
}
export interface ElementSpec {
  electron: { selector: string; textSelector?: string };
  swift: string;
  first?: boolean;
  text?: boolean;
  geometry?: boolean;
}
interface ReportEntry {
  index: number;
  step: string;
  status: string;
  message?: string;
  check?: { passed: boolean; detail: string };
}
interface Report {
  scenario: string;
  side: string;
  steps: ReportEntry[];
  error?: string;
}

export interface Row {
  element: string;
  index: number;
  status: "ok" | "off" | "style" | "missing-a" | "missing-b" | "absent" | "uncaptured-a" | "uncaptured-b";
  a?: Element;
  b?: Element;
  delta?: number;
  style?: string[];
}

const FRAME_TOLERANCE = 1;

function arg(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function readJSON<T>(path: string): T | null {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null;
  }
}

const byPosition = (left: Element, right: Element) =>
  left.frame.y - right.frame.y || left.frame.x - right.frame.x;

export function frameDelta(a: Frame, b: Frame): number {
  return Math.max(
    Math.abs(a.x - b.x),
    Math.abs(a.y - b.y),
    Math.abs(a.width - b.width),
    Math.abs(a.height - b.height),
  );
}

/// Pairs each named element of the two dumps and says how far apart they are. An element one
/// side has and the other doesn't is "missing" on that side, not "off". A name a dump's capture didn't
/// look for (named after a cached capture was taken) is "uncaptured" on that side and not compared.
export function compareGeometry(a: Dump, b: Dump, specs: Record<string, ElementSpec>): Row[] {
  const rows: Row[] = [];
  for (const [name, spec] of Object.entries(specs)) {
    if (spec.geometry === false) continue;
    const uncaptured = (dump: Dump) => dump.captured !== undefined && !dump.captured.includes(spec.swift);
    if (uncaptured(a) || uncaptured(b)) {
      rows.push({ element: name, index: 0, status: uncaptured(a) ? "uncaptured-a" : "uncaptured-b" });
      continue;
    }
    let left = a.elements.filter((e) => e.id === spec.swift).sort(byPosition);
    let right = b.elements.filter((e) => e.id === spec.swift).sort(byPosition);
    if (spec.first) {
      left = left.slice(0, 1);
      right = right.slice(0, 1);
    }
    if (left.length === 0 && right.length === 0) {
      rows.push({ element: name, index: 0, status: "absent" });
      continue;
    }
    for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
      const ea = left[index];
      const eb = right[index];
      if (!ea || !eb) {
        rows.push({ element: name, index, status: ea ? "missing-b" : "missing-a", a: ea, b: eb });
        continue;
      }
      const delta = frameDelta(ea.frame, eb.frame);
      const style: string[] = [];
      if (spec.text) {
        const ta = ea.text;
        const tb = eb.text;
        if (!ta || !tb) {
          if (ta || tb) style.push("text");
        } else {
          if (ta.fontSize !== tb.fontSize) style.push(`size ${ta.fontSize}/${tb.fontSize}`);
          if (ta.fontWeight !== tb.fontWeight) style.push(`weight ${ta.fontWeight}/${tb.fontWeight}`);
          if ((ta.color ?? "").toLowerCase() !== (tb.color ?? "").toLowerCase()) {
            style.push(`color ${ta.color}/${tb.color}`);
          }
        }
      }
      const status = delta > FRAME_TOLERANCE ? "off" : style.length > 0 ? "style" : "ok";
      rows.push({ element: name, index, status, a: ea, b: eb, delta, style });
    }
  }
  return rows;
}

export interface GeometrySummary {
  /// Logical elements with a row off by more than the tolerance, or in another style.
  off: number;
  /// Logical elements with a row only side B has (missing on side A), and the other way round.
  missingA: number;
  missingB: number;
  /// Logical elements a side's capture didn't look for (named after it was taken; not compared).
  uncapturedA?: number;
  uncapturedB?: number;
  /// Logical elements either side has (an element neither side has doesn't count).
  total: number;
  /// The largest frame difference of a pair, in points.
  max: number;
}

export function geometrySummary(rows: Row[]): GeometrySummary {
  const names = (keep: (row: Row) => boolean) => new Set(rows.filter(keep).map((r) => r.element)).size;
  return {
    off: names((r) => r.status === "off" || r.status === "style"),
    missingA: names((r) => r.status === "missing-a"),
    missingB: names((r) => r.status === "missing-b"),
    uncapturedA: names((r) => r.status === "uncaptured-a"),
    uncapturedB: names((r) => r.status === "uncaptured-b"),
    total: names((r) => r.status !== "absent" && !r.status.startsWith("uncaptured")),
    max: rows.reduce((worst, r) => Math.max(worst, r.delta ?? 0), 0),
  };
}

/// "2 off, 9 missing (swift)": what the runner line and the contact sheet say of the geometry.
export function geometryText(g: GeometrySummary, labelA: string, labelB: string): string {
  const parts = [`${g.off} off`];
  if (g.missingB > 0) parts.push(`${g.missingB} missing (${labelB})`);
  if (g.missingA > 0) parts.push(`${g.missingA} missing (${labelA})`);
  const max = g.max > 0 ? ` (max ${Math.round(g.max * 10) / 10}pt)` : "";
  const later: string[] = [];
  if (g.uncapturedA) later.push(`${g.uncapturedA} not in the ${labelA} capture`);
  if (g.uncapturedB) later.push(`${g.uncapturedB} not in the ${labelB} capture`);
  return `${parts.join(", ")} of ${g.total}${max}${later.length ? `; ${later.join(", ")} (--refresh-original)` : ""}`;
}

/// A row's status as the contact sheet shows it.
export function rowStatusText(status: Row["status"], labelA: string, labelB: string): string {
  if (status === "missing-a") return `missing (${labelA})`;
  if (status === "missing-b") return `missing (${labelB})`;
  if (status === "uncaptured-a") return `not captured (${labelA})`;
  if (status === "uncaptured-b") return `not captured (${labelB})`;
  return status;
}

function compare() {
  const scenarioFile = arg("--scenario");
  const dirA = arg("--a");
  const dirB = arg("--b");
  const out = arg("--out");
  if (!scenarioFile || !dirA || !dirB || !out) {
    console.error("usage: report.ts compare --scenario <file> --a <dir> --b <dir> --out <dir>");
    process.exit(2);
  }
  const here = dirname(new URL(import.meta.url).pathname);
  const specs = (readJSON<{ elements: Record<string, ElementSpec> }>(arg("--elements") ?? join(here, "elements.json")))
    ?.elements;
  if (!specs) throw new Error("could not read elements.json");
  const pixeldiff = arg("--pixeldiff") ?? "build/pixeldiff/pixeldiff";
  const labelA = arg("--label-a") ?? "electron";
  const labelB = arg("--label-b") ?? "swift";
  const scenario = readJSON<{
    name: string;
    description?: string;
    features?: string[];
    behaviors?: string[];
    steps: { step: string; name?: string }[];
  }>(scenarioFile);
  if (!scenario) throw new Error(`could not read ${scenarioFile}`);
  mkdirSync(out, { recursive: true });

  const problems: string[] = [];
  const reportA = readJSON<Report>(join(dirA, "report.json"));
  const reportB = readJSON<Report>(join(dirB, "report.json"));
  for (const [label, report] of [
    [labelA, reportA],
    [labelB, reportB],
  ] as const) {
    if (!report) problems.push(`${label}: no report.json`);
    else if (report.error) problems.push(`${label}: ${report.error.split("\n")[0]}`);
  }

  const snapshots: unknown[] = [];
  const geometries: unknown[] = [];
  let worstPixels = 0;
  let geometry: GeometrySummary = { off: 0, missingA: 0, missingB: 0, total: 0, max: 0 };
  const allRows: Row[] = [];
  for (const step of scenario.steps) {
    if (step.step === "geometry" && step.name) {
      const a = readJSON<Dump>(join(dirA, `${step.name}.json`));
      const b = readJSON<Dump>(join(dirB, `${step.name}.json`));
      if (!a || !b) {
        problems.push(`geometry ${step.name}: missing on ${!a ? labelA : labelB}`);
        continue;
      }
      const rows = compareGeometry(a, b, specs);
      allRows.push(...rows);
      geometries.push({ name: step.name, rows });
    } else if (step.step === "snapshot" && step.name) {
      const a = join(dirA, `${step.name}.png`);
      const b = join(dirB, `${step.name}.png`);
      if (!existsSync(a) || !existsSync(b)) {
        problems.push(`snapshot ${step.name}: missing on ${!existsSync(a) ? labelA : labelB}`);
        continue;
      }
      const diffDir = join(out, step.name);
      // Regions and an extra scroller mask from side A's geometry of the same name, when there is one.
      const dumpA = readJSON<Dump>(join(dirA, `${step.name}.json`));
      const regions: Frame[] = [];
      const masks: Frame[] = [];
      for (const [name, spec] of Object.entries(specs)) {
        if (spec.first || !["sidebar", "toolbar", "content", "status bar"].includes(name)) continue;
        const element = dumpA?.elements.find((e) => e.id === spec.swift);
        if (!element) continue;
        regions.push({ name, ...element.frame } as Frame);
        if (name === "sidebar") {
          const f = element.frame;
          masks.push({ name: "sidebar scroller", x: f.x + f.width - 16, y: f.y, width: 16, height: f.height } as Frame);
        }
      }
      mkdirSync(diffDir, { recursive: true });
      writeFileSync(join(diffDir, "regions.json"), JSON.stringify(regions));
      writeFileSync(join(diffDir, "masks.json"), JSON.stringify(masks));
      const run = spawnSync(
        pixeldiff,
        [a, b, "--out", diffDir, "--regions", join(diffDir, "regions.json"), "--mask", join(diffDir, "masks.json")],
        { encoding: "utf8" },
      );
      const result = readJSON<{ overall: { score: number }; regions: { name: string; score: number }[] }>(
        join(diffDir, "pixeldiff.json"),
      );
      if (run.status !== 0 || !result) {
        problems.push(`pixeldiff ${step.name}: ${(run.stderr || "failed").trim().split("\n")[0]}`);
        continue;
      }
      worstPixels = Math.max(worstPixels, result.overall.score);
      snapshots.push({
        name: step.name,
        a: relative(out, a),
        b: relative(out, b),
        heat: relative(out, join(diffDir, "heat.png")),
        score: result.overall.score,
        regions: result.regions,
      });
    }
  }
  geometry = geometrySummary(allRows);

  const notable = (report: Report | null) =>
    (report?.steps ?? [])
      .filter((s) => s.status !== "ok" || s.check?.passed === false)
      .map((s) => ({ ...s, side: report?.side }));
  const notes = [...notable(reportA), ...notable(reportB)];
  const unsupported = notes.filter((s) => s.status === "unsupported" || s.status === "partial").length;
  const failedA = notable(reportA).filter((s) => s.status === "failed" || s.status === "timeout");
  const failedB = notable(reportB).filter((s) => s.status === "failed" || s.status === "timeout");
  // The reference must do every step and meet every expectation (they describe what it does);
  // this app failing one is a difference to report.
  for (const step of failedA) problems.push(`${labelA} step ${step.index} (${step.step}): ${step.message ?? step.status}`);
  for (const step of notable(reportA).filter((s) => s.check?.passed === false)) {
    problems.push(`${labelA} step ${step.index} (expect): ${step.check?.detail}`);
  }
  const unmetB = notable(reportB).filter((s) => s.check?.passed === false).length;

  const summary = {
    scenario: scenario.name,
    description: scenario.description ?? "",
    features: scenario.features ?? [],
    behaviors: scenario.behaviors ?? [],
    labels: [labelA, labelB],
    geometry,
    pixels: worstPixels,
    unsupported,
    failed: failedB.length,
    unmet: unmetB,
    problems,
    notes,
    snapshots,
    geometries,
  };
  writeFileSync(join(out, "summary.json"), `${JSON.stringify(summary, null, 2)}\n`);
  let line = `${scenario.name.padEnd(28)}  geometry: ${geometryText(geometry, labelA, labelB)}  pixels: ${worstPixels.toFixed(2)}  unsupported: ${unsupported} steps`;
  if (failedB.length > 0) line += `  failed: ${failedB.length} steps`;
  if (unmetB > 0) line += `  expect: ${unmetB} unmet (${labelB})`;
  if (problems.length > 0) line += `  PIPELINE: ${problems.join("; ")}`;
  console.log(line);
  const miss = geometry.off + geometry.missingA + geometry.missingB > 0 || unmetB > 0;
  process.exit(problems.length > 0 ? 3 : miss ? 1 : 0);
}

function escape(text: string): string {
  return text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c] ?? c);
}

function contact() {
  const out = arg("--out");
  if (!out) {
    console.error("usage: report.ts contact --out <dir>");
    process.exit(2);
  }
  const sections: string[] = [];
  const names = readdirSync(out, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();
  const fmt = (f?: Frame) => (f ? `${f.x}, ${f.y}, ${f.width}×${f.height}` : "—");
  const fmtText = (t?: Text) => (t ? `${t.fontSize ?? "?"}px ${t.fontWeight ?? "?"} ${t.color ?? ""}` : "");
  for (const name of names) {
    // biome-ignore lint/suspicious/noExplicitAny: summary.json is our own format.
    const summary = readJSON<any>(join(out, name, "diff", "summary.json"));
    if (!summary) continue;
    const [labelA, labelB] = summary.labels as string[];
    const prefix = `${name}/diff/`;
    const images = (summary.snapshots as { name: string; a: string; b: string; heat: string; score: number }[])
      .map(
        (s) => `<figure class="row">
  <div><figcaption>${escape(labelA)} · ${escape(s.name)}</figcaption><img src="${prefix}${s.a}" loading="lazy"></div>
  <div><figcaption>${escape(labelB)}</figcaption><img src="${prefix}${s.b}" loading="lazy"></div>
  <div><figcaption>difference · ${s.score.toFixed(3)}</figcaption><img src="${prefix}${s.heat}" loading="lazy"></div>
</figure>`,
      )
      .join("\n");
    const tables = (summary.geometries as { name: string; rows: Row[] }[])
      .map(
        (g) => `<table><caption>geometry ${escape(g.name)}</caption>
<tr><th>element</th><th>#</th><th>status</th><th>${escape(labelA)}</th><th>${escape(labelB)}</th><th>Δ pt</th><th>text</th></tr>
${g.rows
  .map(
    (r) => `<tr class="${r.status}"><td>${escape(r.element)}</td><td>${r.index}</td><td>${escape(rowStatusText(r.status, labelA, labelB))}</td><td>${fmt(r.a?.frame)}</td><td>${fmt(r.b?.frame)}</td><td>${r.delta === undefined ? "" : Math.round(r.delta * 10) / 10}</td><td>${escape(
      r.style && r.style.length > 0 ? r.style.join(", ") : `${fmtText(r.a?.text)} | ${fmtText(r.b?.text)}`,
    )}</td></tr>`,
  )
  .join("\n")}
</table>`,
      )
      .join("\n");
    const notes = (summary.notes as (ReportEntry & { side: string })[])
      .map(
        (n) =>
          `<li>${escape(n.side)} step ${n.index} (${escape(n.step)}): ${escape(n.check?.passed === false ? `unmet: ${n.check.detail}` : `${n.status} ${n.message ?? ""}`)}</li>`,
      )
      .concat((summary.problems as string[]).map((p) => `<li class="problem">${escape(p)}</li>`))
      .join("\n");
    sections.push(`<section id="${escape(name)}">
<h2>${escape(summary.scenario)}</h2>
<p class="meta">${escape(summary.description)} — geometry ${escape(geometryText(summary.geometry, labelA, labelB))} · pixels ${summary.pixels.toFixed(3)} · unsupported ${summary.unsupported}${summary.unmet ? ` · ${summary.unmet} expectations unmet` : ""}${(summary.features ?? []).length ? ` · ${escape(summary.features.join(" "))}` : ""}</p>
${images}
${tables}
${notes ? `<ul class="notes">${notes}</ul>` : ""}
</section>`);
  }
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Capture contact sheet</title>
<style>
:root { color-scheme: light dark; --bg: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --bad: #c9341f; --warn: #a15c00; }
@media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #f5f5f7; --muted: #98989d; --line: #3a3a3c; --bad: #ff6b57; --warn: #ffb340; } }
body { margin: 0 auto; padding: 16px; max-width: 1800px; background: var(--bg); color: var(--fg); font: 13px -apple-system, system-ui, sans-serif; }
h1 { font-size: 20px; } h2 { font-size: 16px; margin: 32px 0 4px; } .meta { color: var(--muted); margin: 0 0 8px; }
nav a { margin-right: 12px; color: inherit; }
.row { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; margin: 0 0 8px; }
.row img { width: 100%; border: 1px solid var(--line); display: block; } figcaption { color: var(--muted); margin-bottom: 4px; }
table { border-collapse: collapse; margin: 8px 0; font-variant-numeric: tabular-nums; } caption { text-align: left; color: var(--muted); }
td, th { border-bottom: 1px solid var(--line); padding: 2px 8px; text-align: left; white-space: nowrap; }
tr.off td:nth-child(3), tr.missing-a td:nth-child(3), tr.missing-b td:nth-child(3) { color: var(--bad); } tr.style td:nth-child(3) { color: var(--warn); }
tr.uncaptured-a td, tr.uncaptured-b td { color: var(--muted); }
.notes { color: var(--muted); } .problem { color: var(--bad); }
@media (max-width: 700px) { .row { grid-template-columns: 1fr; } table { display: block; overflow-x: auto; } }
</style></head><body>
<h1>Capture contact sheet</h1>
<nav>${names.map((n) => `<a href="#${escape(n)}">${escape(n)}</a>`).join("")}</nav>
${sections.join("\n")}
</body></html>
`;
  writeFileSync(join(out, "contact.html"), html);
}

/// A hand-made pair of captures with known differences, run through `compare` itself: the sidebar 3 pt
/// to the right, the status bar only on the first side, the list header only on the second, one unmet
/// expectation on the second, and the sidebar section headers only on the second, named after the first
/// side was captured (its `captured` list leaves them out). Checks that the comparison reports exactly that.
function selftest() {
  const out = arg("--out");
  if (!out) {
    console.error("usage: report.ts selftest --out <dir>");
    process.exit(2);
  }
  const here = dirname(new URL(import.meta.url).pathname);
  const dirA = join(out, "electron");
  const dirB = join(out, "swift");
  for (const dir of [dirA, dirB]) mkdirSync(dir, { recursive: true });
  const element = (id: string, x: number, y: number, width: number, height: number, text?: Text): Element => ({
    id,
    frame: { x, y, width, height },
    ...(text ? { text } : {}),
  });
  const title: Text = { string: "components", fontSize: 13, fontWeight: 700, color: "#000000d8" };
  const shared = [
    element("toolbar", 0, 0, 1200, 52),
    element("toolbar.title", 120, 16, 90, 18, title),
    element("content", 280, 52, 920, 680),
  ];
  const dumpA: Dump = {
    format: "filetrail-geometry/1",
    side: "electron",
    name: "main",
    window: { width: 1200, height: 760 },
    elements: [...shared, element("sidebar", 0, 52, 280, 708), element("statusBar", 280, 736, 920, 24)],
  };
  const specs = readJSON<{ elements: Record<string, ElementSpec> }>(join(here, "elements.json"))?.elements ?? {};
  dumpA.captured = Object.values(specs)
    .filter((spec) => spec.geometry !== false && spec.swift !== "sidebar.sectionHeader")
    .map((spec) => spec.swift);
  const dumpB: Dump = {
    ...dumpA,
    side: "swift",
    captured: undefined,
    elements: [
      ...shared,
      element("sidebar", 3, 52, 280, 708),
      element("list.header", 280, 52, 920, 28),
      element("sidebar.sectionHeader", 12, 60, 256, 20),
    ],
  };
  writeFileSync(join(dirA, "main.json"), JSON.stringify(dumpA));
  writeFileSync(join(dirB, "main.json"), JSON.stringify(dumpB));
  const expectStep = (passed: boolean) => ({
    index: 2,
    step: "expect",
    status: "ok",
    milliseconds: 1,
    check: { passed, detail: passed ? "title: text “components”" : "title: text “Lighthouse”, expected “components”" },
  });
  const geometryStep = { index: 1, step: "geometry", status: "ok", milliseconds: 1 };
  writeFileSync(
    join(dirA, "report.json"),
    JSON.stringify({ scenario: "selftest", side: "electron", steps: [geometryStep, expectStep(true)] }),
  );
  writeFileSync(
    join(dirB, "report.json"),
    JSON.stringify({ scenario: "selftest", side: "swift", steps: [geometryStep, expectStep(false)] }),
  );
  const scenarioFile = join(out, "selftest.json");
  writeFileSync(
    scenarioFile,
    JSON.stringify({
      name: "selftest-known-offsets",
      steps: [
        { step: "geometry", name: "main" },
        { step: "expect", element: "title", text: "components" },
      ],
    }),
  );
  const run = spawnSync(
    process.execPath,
    [
      new URL(import.meta.url).pathname,
      "compare",
      "--scenario",
      scenarioFile,
      "--a",
      dirA,
      "--b",
      dirB,
      "--out",
      join(out, "diff"),
      "--elements",
      join(here, "elements.json"),
    ],
    { encoding: "utf8" },
  );
  const summary = readJSON<{ geometry: GeometrySummary; unmet: number; problems: string[] }>(
    join(out, "diff", "summary.json"),
  );
  const line = run.stdout.trim();
  const failures: string[] = [];
  if (run.status !== 1) failures.push(`compare exited ${run.status}, expected 1 (a geometry miss)`);
  if (!summary) failures.push("no summary.json");
  else {
    const g = summary.geometry;
    if (g.off !== 1 || g.max !== 3) failures.push(`off ${g.off} (max ${g.max} pt), expected 1 off by 3 pt`);
    if (g.missingB !== 1) failures.push(`${g.missingB} missing (swift), expected 1`);
    if (g.missingA !== 1) failures.push(`${g.missingA} missing (electron), expected 1`);
    if (g.total !== 6) failures.push(`${g.total} elements, expected 6`);
    if (g.uncapturedA !== 1) failures.push(`${g.uncapturedA} not captured (electron), expected 1`);
    if (summary.unmet !== 1) failures.push(`${summary.unmet} unmet expectations, expected 1`);
    if (summary.problems.length > 0) failures.push(`problems: ${summary.problems.join("; ")}`);
  }
  if (
    !line.includes(
      "geometry: 1 off, 1 missing (swift), 1 missing (electron) of 6 (max 3pt); 1 not in the electron capture",
    )
  ) {
    failures.push(`runner line: ${line}`);
  }
  if (failures.length > 0) {
    console.log(`selftest known offsets: FAILED (${failures.join("; ")})`);
    process.exit(1);
  }
  console.log(
    "selftest known offsets: passed (1 off by 3 pt, 1 missing on each side, 1 not captured, 1 unmet expectation)",
  );
}

if (import.meta.main) {
  const command = process.argv[2];
  if (command === "compare") compare();
  else if (command === "contact") contact();
  else if (command === "selftest") selftest();
  else {
    console.error("usage: report.ts compare|contact|selftest …");
    process.exit(2);
  }
}
