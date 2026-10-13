// Prints a compact summary of docs/port/parity/tests.tsv and features.md by class, area and status.
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const DIR = resolve(dirname(new URL(import.meta.url).pathname), "../../docs/port/parity");

function tally(keys: string[]): Map<string, number> {
  const m = new Map<string, number>();
  for (const k of keys) m.set(k, (m.get(k) ?? 0) + 1);
  return m;
}

function table(title: string, rows: Map<string, Map<string, number>>, statuses: string[]): string {
  const lines = [title, `  ${"".padEnd(24)}${["total", ...statuses].map((s) => s.padStart(8)).join("")}`];
  for (const [name, byStatus] of [...rows].sort(([a], [b]) => (a < b ? -1 : 1))) {
    const total = [...byStatus.values()].reduce((a, b) => a + b, 0);
    lines.push(`  ${name.padEnd(24)}${[total, ...statuses.map((s) => byStatus.get(s) ?? 0)].map((n) => String(n).padStart(8)).join("")}`);
  }
  return lines.join("\n");
}

function group(pairs: [string, string][]): Map<string, Map<string, number>> {
  const out = new Map<string, Map<string, number>>();
  for (const [g, s] of pairs) {
    const inner = out.get(g) ?? new Map<string, number>();
    inner.set(s, (inner.get(s) ?? 0) + 1);
    out.set(g, inner);
  }
  return out;
}

function testsReport(): string {
  const path = `${DIR}/tests.tsv`;
  if (!existsSync(path)) return "tests.tsv: missing";
  const rows = readFileSync(path, "utf8").split("\n").filter((l) => l).slice(1).map((l) => l.split("\t"));
  const statuses = ["todo", "ported", "passing", "N/A", "cov-by-F", "gone"];
  const known = (s: string): string => (statuses.includes(s) ? s : s.startsWith("N/A") ? "N/A" : s.startsWith("covered-by-feature") ? "cov-by-F" : s);
  const byClass = group(rows.map((r) => [r[5] ?? "", known(r[8] ?? "")]));
  const byArea = group(rows.map((r) => [r[6] ?? "", known(r[8] ?? "")]));
  const live = rows.filter((r) => r[8] !== "gone").length;
  const done = rows.filter((r) => ["ported", "passing"].includes(r[8] ?? "")).length;
  return [`Tests: ${live} cases, ${done} ported or passing`, table("By class", byClass, statuses), table("By area", byArea, statuses)].join("\n");
}

function featuresReport(): string {
  const path = `${DIR}/features.md`;
  if (!existsSync(path)) return "features.md: missing";
  let area = "";
  const pairs: [string, string][] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const h = /^##\s+(.*)$/.exec(line);
    if (h) area = (h[1] ?? "").trim();
    if (/^\| F-\d+/.test(line)) {
      const cells = line.split("|").map((c) => c.trim());
      pairs.push([area, cells[cells.length - 2] ?? ""]);
    }
  }
  const statuses = ["todo", "partial", "done"];
  const overall = tally(pairs.map(([, s]) => s));
  return [`Features: ${pairs.length} rows (${[...overall].map(([s, n]) => `${s} ${n}`).join(", ")})`, table("By area", group(pairs), statuses)].join("\n");
}

console.log(testsReport());
console.log("");
console.log(featuresReport());
