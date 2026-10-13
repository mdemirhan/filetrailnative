// Moves parity status by script: reads the citations in Tests/**/*.swift and the capture scenarios,
// then updates docs/port/parity/tests.tsv and features.md. See tools/parity-matrix/README.md.
//
//   bun tools/parity-matrix/sync.ts            run the tests, then update both files
//   bun tools/parity-matrix/sync.ts --no-run   use the last result in build/logs/ instead of running
//   bun tools/parity-matrix/sync.ts --check    change nothing; exit 1 if a file would change or a citation is invalid
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), "../..");
const TESTS_TSV = join(ROOT, "docs/port/parity/tests.tsv");
const FEATURES_MD = join(ROOT, "docs/port/parity/features.md");
const BEHAVIORS_TSV = join(ROOT, "docs/port/parity/behaviors.tsv");
const BEHAVIORS_DIR = join(ROOT, "docs/port/behaviors");
const SCENARIOS = join(ROOT, "tools/capture/scenarios");
const CAPTURE_OUT = join(ROOT, "tools/capture/out");
const XUNIT = join(ROOT, "build/logs/parity-xunit.xml");
// Swift Testing writes its results next to the requested path, with this suffix.
const XUNIT_SWIFT_TESTING = join(ROOT, "build/logs/parity-xunit-swift-testing.xml");

const args = new Set(process.argv.slice(2));
const CHECK = args.has("--check");
const NO_RUN = args.has("--no-run") || CHECK;

const COLUMNS = ["id", "file", "describe", "title", "form", "class", "area", "swiftTarget", "status", "swiftTest", "note"] as const;
type Row = Record<(typeof COLUMNS)[number], string>;

// ---------------------------------------------------------------- Swift sources

interface SwiftTest {
  key: string; // Target/function, the name written into the matrix
  target: string;
  fn: string;
  display?: string;
}
interface Citation {
  file: string;
  line: number;
  ids: string[];
  kind: "cite" | "covered" | "na";
  reason: string;
  test?: SwiftTest;
}

const ID_T = /^T-[0-9a-f]{8}$/;
const ID_F = /^F-\d{3,4}$/;
const ID_B = /^B-[A-Z]+-\d{3}$/;

function walkSwift(dir: string, out: string[]): void {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir).sort()) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walkSwift(p, out);
    else if (name.endsWith(".swift")) out.push(p);
  }
}

// A citation comment starts with ids (`// T-1a2b3c4d F-12`), `covered-by-feature` or `N/A`.
const CITE_LINE = /^\s*\/\/\s*((?:[TFB]-\S*[\s,]*)+)$/;
const COVERED_LINE = /^\s*\/\/\s*covered-by-feature\s+(.*)$/;
const NA_LINE = /^\s*\/\/\s*N\/A\s+(.*)$/;

function scanSwift(): Citation[] {
  const files: string[] = [];
  walkSwift(join(ROOT, "Tests"), files);
  const found: Citation[] = [];
  for (const abs of files) {
    const file = relative(ROOT, abs);
    const target = file.split("/")[1] ?? "";
    const lines = readFileSync(abs, "utf8").split("\n");
    // Every @Test function, with the line of its attribute and of its closing brace.
    const tests: { start: number; end: number; test: SwiftTest }[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i] ?? "";
      if (!/^\s*@Test\b/.test(line)) continue;
      let display: string | undefined;
      const d = /@Test\(\s*"((?:[^"\\]|\\.)*)"/.exec(line);
      if (d) display = d[1];
      let j = i;
      let fn: string | undefined;
      for (; j < Math.min(lines.length, i + 8); j++) {
        const m = /\bfunc\s+(\w+)/.exec(lines[j] ?? "");
        if (m) {
          fn = m[1];
          break;
        }
      }
      if (!fn) continue;
      let depth = 0;
      let opened = false;
      let end = j;
      for (let k = j; k < lines.length; k++) {
        const stripped = (lines[k] ?? "").replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/\/\/.*$/, "");
        for (const ch of stripped) {
          if (ch === "{") {
            depth++;
            opened = true;
          } else if (ch === "}") depth--;
        }
        end = k;
        if (opened && depth <= 0) break;
      }
      tests.push({ start: i, end, test: { key: `${target}/${fn}`, target, fn, display } });
    }
    const owner = (i: number): SwiftTest | undefined => {
      const inside = tests.find((t) => i >= t.start && i <= t.end);
      if (inside) return inside.test;
      // Otherwise the comment sits on the lines before an attribute.
      let j = i + 1;
      while (j < lines.length && /^\s*(\/\/.*)?$/.test(lines[j] ?? "")) j++;
      return tests.find((t) => t.start === j)?.test;
    };
    lines.forEach((text, i) => {
      const line = i + 1;
      let m: RegExpExecArray | null;
      if ((m = COVERED_LINE.exec(text))) {
        found.push({ file, line, kind: "covered", ids: m[1]!.split(/[\s,]+/).filter((t) => /^[TFB]-/.test(t)), reason: "", test: owner(i) });
      } else if ((m = NA_LINE.exec(text))) {
        const words = m[1]!.split(/\s+/);
        const ids: string[] = [];
        while (words.length && /^[TFB]-\S*?,?$/.test(words[0]!)) ids.push(words.shift()!.replace(/,$/, ""));
        found.push({ file, line, kind: "na", ids, reason: words.join(" "), test: owner(i) });
      } else if ((m = CITE_LINE.exec(text))) {
        found.push({ file, line, kind: "cite", ids: m[1]!.split(/[\s,]+/).filter(Boolean), reason: "", test: owner(i) });
      }
    });
  }
  return found;
}

// ---------------------------------------------------------------- results

type Outcome = "pass" | "fail";

function loadResults(): Map<string, Outcome> | undefined {
  const path = [XUNIT_SWIFT_TESTING, XUNIT].find((p) => existsSync(p) && /<testcase /.test(readFileSync(p, "utf8")));
  if (!path) return undefined;
  const results = new Map<string, Outcome>();
  const xml = readFileSync(path, "utf8");
  const decode = (s: string): string => s.replaceAll("&quot;", '"').replaceAll("&apos;", "'").replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&");
  for (const m of xml.matchAll(/<testcase\s+([^>]*?)(\/>|>([\s\S]*?)<\/testcase>)/g)) {
    const attrs = Object.fromEntries([...m[1]!.matchAll(/(\w+)="([^"]*)"/g)].map((a) => [a[1]!, decode(a[2]!)]));
    const body = m[3] ?? "";
    const outcome: Outcome = /<(failure|error|skipped)\b/.test(body) ? "fail" : "pass";
    const target = (attrs.classname ?? "").split(".")[0] ?? "";
    const name = (attrs.name ?? "").replace(/\(.*\)$/, "");
    const key = `${target}/${name}`;
    // Parameterized tests report one case each: all must pass.
    results.set(key, results.get(key) === "fail" || outcome === "fail" ? "fail" : "pass");
  }
  return results;
}

function runTests(): void {
  const r = spawnSync("swift", ["test", "--parallel", "--xunit-output", XUNIT], { cwd: ROOT, stdio: ["ignore", "ignore", "pipe"], encoding: "utf8" });
  // A failing test still writes the results; only a build failure leaves none.
  if (r.status !== 0 && !existsSync(XUNIT_SWIFT_TESTING) && !existsSync(XUNIT)) {
    console.error(`swift test did not produce results:\n${(r.stderr ?? "").split("\n").slice(-20).join("\n")}`);
    process.exit(2);
  }
}

// ---------------------------------------------------------------- tests.tsv

function readRows(): Row[] {
  const lines = readFileSync(TESTS_TSV, "utf8").split("\n").filter((l) => l.length > 0);
  return lines.slice(1).map((line) => {
    const cells = line.split("\t");
    return Object.fromEntries(COLUMNS.map((c, i) => [c, cells[i] ?? ""])) as Row;
  });
}

const MANUAL = (s: string): boolean => s === "gone" || s.startsWith("N/A") || s.startsWith("covered-by-feature");

// ---------------------------------------------------------------- features.md

interface FeatureRow {
  id: string;
  feature: string;
  spec: string;
  wp: string;
  status: string;
}

function splitCells(line: string): string[] {
  const body = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return body.split(/(?<!\\)\|/).map((c) => c.trim());
}

function scenarioIds(key: "features" | "behaviors"): Map<string, string[]> {
  const byFeature = new Map<string, string[]>();
  if (!existsSync(SCENARIOS)) return byFeature;
  for (const name of readdirSync(SCENARIOS).sort()) {
    if (!name.endsWith(".json")) continue;
    const data = JSON.parse(readFileSync(join(SCENARIOS, name), "utf8")) as { features?: string[]; behaviors?: string[] };
    for (const f of data[key] ?? []) byFeature.set(f, [...(byFeature.get(f) ?? []), name.replace(/\.json$/, "")]);
  }
  return byFeature;
}

/** pass or fail when a diff summary exists for the scenario, unknown otherwise. */
function scenarioOutcome(name: string): Outcome | "unknown" {
  const path = join(CAPTURE_OUT, name, "diff", "summary.json");
  if (!existsSync(path)) return "unknown";
  try {
    const s = JSON.parse(readFileSync(path, "utf8")) as { geometry?: { off?: number }; problems?: string[] };
    return (s.geometry?.off ?? 0) === 0 && (s.problems ?? []).length === 0 ? "pass" : "fail";
  } catch {
    return "unknown";
  }
}

// ---------------------------------------------------------------- behaviors

interface Behavior {
  id: string;
  area: string;
  text: string;
  evidence: string;
}

// Which improvements (PLAN.md §3.4a table A1..A17) each behavior file refines.
const AREA_IMPROVEMENTS: Record<string, string> = {
  NAV: "A8, A14",
  SEL: "A7",
  INFO: "A8, A11",
  SRCH: "A1",
  TREE: "A2, A16",
  CLIP: "A3, A4, A5, A17",
  VIEW: "A10, A13, A14",
  DLG: "A6, A9, A12, A15",
};

function readBehaviors(): Behavior[] {
  const out: Behavior[] = [];
  if (!existsSync(BEHAVIORS_DIR)) return out;
  for (const name of readdirSync(BEHAVIORS_DIR).sort()) {
    if (!name.endsWith(".md") || name === "README.md") continue;
    for (const line of readFileSync(join(BEHAVIORS_DIR, name), "utf8").split("\n")) {
      const m = /^\| (B-([A-Z]+)-\d{3}) \|/.exec(line);
      if (!m) continue;
      // Rules may hold unescaped pipes inside code spans: take the first cells and the last two.
      const cells = line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
      out.push({ id: m[1]!, area: m[2]!, text: cells.slice(1, -2).join("|"), evidence: cells[cells.length - 2] ?? "" });
    }
  }
  return out;
}

function readBehaviorStatuses(): Map<string, string> {
  const m = new Map<string, string>();
  if (!existsSync(BEHAVIORS_TSV)) return m;
  for (const line of readFileSync(BEHAVIORS_TSV, "utf8").split("\n").slice(1)) {
    const c = line.split("\t");
    if (c[0]) m.set(c[0], c[5] ?? "todo");
  }
  return m;
}

/** Identifier-like words (camelCase, snake_case, file names) that tie a feature row to a rule. */
function identifiers(text: string): Set<string> {
  const out = new Set<string>();
  for (const m of text.matchAll(/[A-Za-z][A-Za-z0-9_]*(?:\.[a-z]{2,4})?/g)) {
    const w = m[0];
    if (w.length < 6) continue;
    if (/[a-z][A-Z]/.test(w) || w.includes("_") || /\.(tsx?|json)$/.test(w)) out.add(w.replace(/\.(tsx?|json)$/, "").toLowerCase());
  }
  return out;
}

/** F id -> B ids that refine it: two shared identifiers, or one that is rare on both sides. */
function linkBehaviors(featureRows: Map<string, string>, behaviors: Behavior[]): Map<string, string[]> {
  const bIds = new Map(behaviors.map((b) => [b.id, identifiers(`${b.text} ${b.evidence.replace(/:[\d,\-; ]+/g, " ")}`)]));
  const bCount = new Map<string, number>();
  for (const set of bIds.values()) for (const w of set) bCount.set(w, (bCount.get(w) ?? 0) + 1);
  const fIds = new Map([...featureRows].map(([id, text]) => [id, identifiers(text)]));
  const fCount = new Map<string, number>();
  for (const set of fIds.values()) for (const w of set) fCount.set(w, (fCount.get(w) ?? 0) + 1);
  const links = new Map<string, string[]>();
  for (const [fid, fset] of fIds) {
    const scored: { id: string; score: number }[] = [];
    for (const [bid, bset] of bIds) {
      const shared = [...fset].filter((w) => bset.has(w));
      const rare = shared.filter((w) => (bCount.get(w) ?? 0) <= 3 && (fCount.get(w) ?? 0) <= 3);
      if (shared.length >= 2 || rare.length >= 1) scored.push({ id: bid, score: shared.length + rare.length });
    }
    scored.sort((a, b) => b.score - a.score || (a.id < b.id ? -1 : 1));
    const top = scored.slice(0, 8).map((x) => x.id).sort();
    if (top.length) links.set(fid, top);
  }
  return links;
}

// ---------------------------------------------------------------- main

function main(): void {
  const rows = readRows();
  const byId = new Map(rows.map((r) => [r.id, r]));
  const featureText = readFileSync(FEATURES_MD, "utf8");
  const featureIds = new Set([...featureText.matchAll(/^\| (F-\d+) \|/gm)].map((m) => m[1]!));

  const behaviors = readBehaviors();
  const behaviorIds = new Set(behaviors.map((b) => b.id));
  const errors: string[] = [];
  const citations = scanSwift();
  for (const c of citations) {
    if (c.ids.length === 0) errors.push(`${c.file}:${c.line}: citation without ids`);
    for (const id of c.ids) {
      const known = ID_T.test(id) ? byId.has(id) : ID_F.test(id) ? featureIds.has(id) : ID_B.test(id) ? behaviorIds.has(id) : false;
      if (!known) errors.push(`${c.file}:${c.line}: unknown id ${id}`);
    }
  }
  const scenarioB = scenarioIds("behaviors");
  for (const [id, names] of scenarioB) if (!behaviorIds.has(id)) errors.push(`scenario ${names.join(", ")}: unknown behavior id ${id}`);
  if (errors.length) {
    console.error(errors.join("\n"));
    if (CHECK) process.exit(1);
    console.error(`${errors.length} invalid citation(s); nothing written`);
    process.exit(1);
  }

  if (!NO_RUN) runTests();
  const results = loadResults();

  const outcomeOf = (t: SwiftTest): Outcome | "unknown" => {
    if (!results) return "unknown";
    return results.get(t.key) ?? (t.display ? results.get(`${t.target}/${t.display}`) : undefined) ?? "unknown";
  };

  // Group the citations by id.
  const testsFor = new Map<string, Map<string, SwiftTest>>();
  const annotation = new Map<string, { status: string; note: string }>();
  const naBehavior = new Map<string, string>();
  const add = (id: string, t: SwiftTest): void => {
    const m = testsFor.get(id) ?? new Map<string, SwiftTest>();
    m.set(t.key, t);
    testsFor.set(id, m);
  };
  for (const c of citations) {
    if (c.kind === "cite") {
      if (c.test) for (const id of c.ids) add(id, c.test);
      else errors.push(`${c.file}:${c.line}: citation is not inside or before a @Test function`);
    } else if (c.kind === "na") {
      for (const id of c.ids) if (ID_T.test(id)) annotation.set(id, { status: "N/A", note: c.reason });
      for (const id of c.ids) if (ID_B.test(id)) naBehavior.set(id, c.reason);
    } else if (c.test) {
      // covered-by-feature F-123 marks the T ids the same test cites.
      const features = c.ids.filter((i) => ID_F.test(i));
      for (const other of citations) {
        if (other.kind === "cite" && other.test?.key === c.test.key) {
          for (const id of other.ids.filter((i) => ID_T.test(i))) annotation.set(id, { status: "covered-by-feature", note: features.join(" ") });
        }
      }
    } else errors.push(`${c.file}:${c.line}: covered-by-feature is not inside or before a @Test function`);
  }
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exit(1);
  }

  // tests.tsv
  const outRows = rows.map((r) => {
    const next = { ...r };
    const note = annotation.get(r.id);
    const cited = [...(testsFor.get(r.id)?.values() ?? [])].sort((a, b) => (a.key < b.key ? -1 : 1));
    if (note) {
      next.status = note.status;
      next.note = note.note;
      next.swiftTest = cited.map((t) => t.key).join(", ");
    } else if (cited.length) {
      next.swiftTest = cited.map((t) => t.key).join(", ");
      const outcomes = cited.map(outcomeOf);
      const wasPassing = r.status === "passing";
      const allPass = outcomes.every((o) => o === "pass" || (o === "unknown" && wasPassing));
      next.status = allPass ? "passing" : "ported";
    } else if (!MANUAL(r.status)) {
      next.status = "todo";
      next.swiftTest = "";
    }
    return next;
  });
  const tsv = [COLUMNS.join("\t"), ...outRows.map((r) => COLUMNS.map((c) => r[c]).join("\t"))].join("\n") + "\n";

  // features.md
  const scenarios = scenarioIds("features");
  const featureTexts = new Map(featureText.split("\n").filter((l) => /^\| F-\d+ \|/.test(l)).map((l) => {
    const c = splitCells(l);
    return [c[0]!, `${c[1]} ${c[2]}`] as [string, string];
  }));
  const links = linkBehaviors(featureTexts, behaviors);
  const lines = featureText.split("\n");
  const outLines = lines.map((line) => {
    if (/^\| ID \| Feature or behavior \|/.test(line)) return "| ID | Feature or behavior | Spec | Planned WP | Tests | Scenario | Behaviors | Status |";
    if (/^\|---\|---\|---\|---\|(---\|)+$/.test(line)) return "|---|---|---|---|---|---|---|---|";
    if (!/^\| F-\d+ \|/.test(line)) return line;
    const cells = splitCells(line);
    const hasNew = cells.length >= 7;
    const [id, feature, spec, wp] = cells as [string, string, string, string];
    const prev = cells[cells.length - 1] ?? "todo";
    const tests = [...(testsFor.get(id)?.values() ?? [])].sort((a, b) => (a.key < b.key ? -1 : 1));
    const scens = scenarios.get(id) ?? [];
    void hasNew;
    const wasDone = prev === "done";
    const evidence: boolean[] = [
      ...tests.map((t) => {
        const o = outcomeOf(t);
        return o === "pass" || (o === "unknown" && wasDone);
      }),
      ...scens.map((s) => {
        const o = scenarioOutcome(s);
        return o === "pass" || (o === "unknown" && wasDone);
      }),
    ];
    let status = prev;
    if (!["todo", "partial", "done"].includes(prev)) status = prev; // a manual status stays
    else if (evidence.length === 0) status = "todo";
    else status = evidence.every(Boolean) ? "done" : "partial";
    return `| ${id} | ${feature} | ${spec} | ${wp} | ${tests.map((t) => t.fn).join(", ")} | ${scens.join(", ")} | ${(links.get(id) ?? []).join(", ")} | ${status} |`;
  });
  const md = outLines.join("\n");

  // behaviors.tsv
  const prevB = readBehaviorStatuses();
  const bRows = behaviors.map((b) => {
    const tests = [...(testsFor.get(b.id)?.values() ?? [])].sort((x, y) => (x.fn < y.fn ? -1 : 1));
    const scens = scenarioB.get(b.id) ?? [];
    const prev = prevB.get(b.id) ?? "todo";
    const wasDone = prev === "done";
    let status: string;
    if (naBehavior.has(b.id)) status = "N/A";
    else if (/\bN\/A D-005\b/.test(b.text)) status = "N/A D-005";
    else {
      const evidence = [
        ...tests.map((t) => {
          const o = outcomeOf(t);
          return o === "pass" || (o === "unknown" && wasDone);
        }),
        ...scens.map((s) => {
          const o = scenarioOutcome(s);
          return o === "pass" || (o === "unknown" && wasDone);
        }),
      ];
      status = evidence.length === 0 ? "todo" : evidence.every(Boolean) ? "done" : "partial";
    }
    return [b.id, b.area, AREA_IMPROVEMENTS[b.area] ?? "", tests.map((t) => t.fn).join(", "), scens.join(", "), status].join("\t");
  });
  const btsv = ["id\tarea\timprovement\ttests\tscenarios\tstatus", ...bRows].join("\n") + "\n";
  const btsvOld = existsSync(BEHAVIORS_TSV) ? readFileSync(BEHAVIORS_TSV, "utf8") : "";

  const changed = [tsv !== readFileSync(TESTS_TSV, "utf8") ? "tests.tsv" : "", md !== featureText ? "features.md" : "", btsv !== btsvOld ? "behaviors.tsv" : ""].filter(Boolean);
  if (CHECK) {
    if (changed.length) {
      console.error(`out of date: ${changed.join(", ")} (run bun tools/parity-matrix/sync.ts)`);
      process.exit(1);
    }
    console.log(`parity matrix up to date (${citations.length} citations)`);
    return;
  }
  if (tsv !== readFileSync(TESTS_TSV, "utf8")) writeFileSync(TESTS_TSV, tsv);
  if (md !== featureText) writeFileSync(FEATURES_MD, md);
  if (btsv !== btsvOld) writeFileSync(BEHAVIORS_TSV, btsv);
  console.log(`parity matrix synced: ${citations.length} citations, updated ${changed.join(", ") || "nothing"}${results ? "" : " (no test results; passing kept as is)"}`);
}

main();
