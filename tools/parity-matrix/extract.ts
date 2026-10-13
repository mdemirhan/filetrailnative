// Extracts every Vitest and Playwright case of the original (pinned commit) into docs/port/parity/tests.tsv.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";

const ORIGINAL = "/Users/tcmudemirhan/src/tsproj/filetrail";
const PINNED = "e4d0872";
const HERE = dirname(new URL(import.meta.url).pathname);
const OUT = resolve(HERE, "../../docs/port/parity/tests.tsv");

const ts: typeof import("typescript") = createRequire(import.meta.url)(`${ORIGINAL}/node_modules/typescript`);

const COLUMNS = ["id", "file", "describe", "title", "form", "class", "area", "swiftTarget", "status", "swiftTest", "note"] as const;
type Row = Record<(typeof COLUMNS)[number], string>;

// Hooks and helpers that share the `test.` / `it.` prefix but are not cases.
const NON_TEST = new Set(["beforeEach", "afterEach", "beforeAll", "afterAll", "use", "step", "setTimeout", "extend", "configure", "slow", "info", "expect"]);
const FACTORY = new Set(["each", "skipIf", "runIf"]);

function walk(dir: string, out: string[]): void {
  for (const name of readdirSync(dir).sort()) {
    if (name === "node_modules" || name === ".git") continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.test\.tsx?$/.test(name) || /\/apps\/desktop\/e2e\/[^/]+\.spec\.ts$/.test(p)) out.push(p);
  }
}

interface Callee {
  root: string;
  props: string[];
  viaCall: boolean;
}

// Unwraps `it.skip.each(table)` style chains down to the root identifier and the property names used.
function analyse(expr: ts.Expression): Callee | undefined {
  const props: string[] = [];
  let viaCall = false;
  let cur: ts.Expression = expr;
  for (;;) {
    if (ts.isPropertyAccessExpression(cur)) {
      props.unshift(cur.name.text);
      cur = cur.expression;
    } else if (ts.isCallExpression(cur)) {
      viaCall = true;
      cur = cur.expression;
    } else if (ts.isParenthesizedExpression(cur) || ts.isNonNullExpression(cur)) {
      cur = cur.expression;
    } else break;
  }
  return ts.isIdentifier(cur) ? { root: cur.text, props, viaCall } : undefined;
}

function titleOf(arg: ts.Expression, sf: ts.SourceFile): string {
  if (ts.isStringLiteral(arg) || ts.isNoSubstitutionTemplateLiteral(arg)) return arg.text;
  const text = arg.getText(sf);
  return ts.isTemplateExpression(arg) ? text.slice(1, -1) : text;
}

interface Found {
  describe: string[];
  title: string;
  form: string;
}

function collect(file: string, text: string): Found[] {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, file.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
  const found: Found[] = [];
  const visit = (node: ts.Node, path: string[]): void => {
    if (ts.isCallExpression(node)) {
      const info = analyse(node.expression);
      const first = node.arguments[0];
      if (info && first && ["it", "test", "describe", "suite"].includes(info.root)) {
        const last = info.props[info.props.length - 1];
        const isFactoryCall = !info.viaCall && last !== undefined && FACTORY.has(last);
        const excluded = info.props.some((p) => NON_TEST.has(p)) || isFactoryCall;
        const isDescribe = info.root === "describe" || info.root === "suite" || info.props.includes("describe");
        const titled = ts.isStringLiteral(first) || ts.isNoSubstitutionTemplateLiteral(first) || ts.isTemplateExpression(first) || ts.isIdentifier(first) || ts.isBinaryExpression(first);
        if (!excluded && titled) {
          const title = titleOf(first, sf);
          if (isDescribe) {
            node.arguments.slice(1).forEach((a) => visit(a, [...path, title]));
            return;
          }
          const p = info.props;
          const form = p.includes("todo") ? "todo" : p.includes("skip") || p.includes("fixme") ? "skip" : p.includes("each") ? "each" : info.root === "test" ? "test" : "it";
          found.push({ describe: path, title, form });
        }
      }
    }
    ts.forEachChild(node, (c) => visit(c, path));
  };
  visit(sf, []);
  return found;
}

function classify(f: string): string {
  const base = f.split("/").pop() ?? f;
  if (f.startsWith("apps/desktop/e2e/")) return "e2e";
  if (f.startsWith("packages/native-fs/")) return "FS";
  if (f.startsWith("apps/desktop/src/preload/")) return "E";
  if (f.startsWith("apps/desktop/src/shared/") || f.startsWith("apps/desktop/scripts/")) return "L";
  if (f.startsWith("packages/contracts/")) return /^(ipc|schemaFreeImports)\./.test(base) ? "E" : "L";
  if (f.startsWith("packages/core/")) {
    if (/\.realfs\./.test(base) || /^(explorerService|undoLog)\.test/.test(base) || /^writeService\.test/.test(base)) return "FS";
    return "L";
  }
  if (f.startsWith("apps/desktop/src/main/bootstrap/")) {
    const fsNames = /^(writeOperations\.(test|windows|undoLog|batchRename)|undoExecution|undo\.(realfs|fuzz)|writeJournal|batchRenameInspect|diskHasTrash|diskIds|systemHandlers\.apps)/;
    return fsNames.test(base) ? "FS" : "L";
  }
  if (f.startsWith("apps/desktop/src/main/")) {
    if (/^(appStateStore|appLog|aboutInfo|fdBinary)\./.test(base)) return "FS";
    if (/^explorerWindowController\./.test(base)) return "UI";
    if (/^(pageWindows|rendererProtocol|ipc)\./.test(base)) return "E";
    return "L";
  }
  if (f.startsWith("apps/desktop/src/renderer/lib/")) return "L";
  return "UI";
}

function areaOf(f: string): string {
  const base = f.split("/").pop() ?? f;
  if (f.startsWith("apps/desktop/e2e/")) return "e2e";
  if (f.startsWith("apps/desktop/src/main/bootstrap/")) return "main/bootstrap";
  if (f.startsWith("apps/desktop/src/main/")) return "main";
  if (f.startsWith("apps/desktop/src/preload/")) return "preload";
  if (f.startsWith("apps/desktop/src/shared/")) return "shared";
  if (f.startsWith("apps/desktop/scripts/")) return "scripts";
  if (f.startsWith("packages/contracts/")) return "contracts";
  if (f.startsWith("packages/core/")) return "core";
  if (f.startsWith("packages/native-fs/")) return "native-fs";
  if (f.startsWith("apps/desktop/src/renderer/lib/")) return "renderer/lib";
  if (f.startsWith("apps/desktop/src/renderer/components/")) return "renderer/components";
  if (f.startsWith("apps/desktop/src/renderer/hooks/")) return "renderer/hooks";
  if (/^App\./.test(base)) return "renderer/App";
  return "renderer/other";
}

function targetOf(f: string, cls: string): string {
  const base = f.split("/").pop() ?? f;
  if (cls === "e2e") return "FTAppKit (automation scenario)";
  if (f.startsWith("packages/native-fs/")) return "FTFileSystem";
  if (f.startsWith("packages/core/")) return /fdSearch|explorerService|explorerWorker|createExplorerFixture|stoppableCopy/.test(base) ? "FTFileSystem" : "FTOperations";
  if (f.startsWith("packages/contracts/")) return /^(ipc|schemaFree)/.test(base) ? "FTFoundation (Codable)" : "FTFoundation";
  if (f.startsWith("apps/desktop/src/shared/") || f.startsWith("apps/desktop/scripts/")) return "FTFoundation";
  if (f.startsWith("apps/desktop/src/preload/")) return "N/A (Electron)";
  if (f.startsWith("apps/desktop/src/main/bootstrap/")) {
    if (/^(systemHandlers|fileDrag|diskHasTrash|diskIds|folderSize|responseCache)/.test(base)) return "FTFileSystem";
    if (/^preferencesPatch/.test(base)) return "FTFoundation";
    return "FTOperations";
  }
  if (f.startsWith("apps/desktop/src/main/")) {
    if (/^(appStateStore|appLog|aboutInfo|fdBinary|diskImages|volumes|folderWatch)/.test(base)) return "FTFileSystem";
    if (/^(rendererProtocol|ipc|pageWindows)/.test(base)) return "N/A (Electron)";
    return "FTAppKit";
  }
  if (f.startsWith("apps/desktop/src/renderer/lib/")) {
    return /Layout|virtualization|scrollbar|pagedScroll|fileDragImages|tooltips|titleTooltips|responsiveLayout|theme|layoutTokens/.test(base) ? "FTAppKit" : "FTFoundation";
  }
  return "FTAppKit";
}

const sha8 = (s: string): string => createHash("sha1").update(s).digest("hex").slice(0, 8);
const clean = (s: string): string => s.replaceAll("\\", "\\\\").replaceAll("\t", "\\t").replaceAll("\r", "").replaceAll("\n", "\\n");

function readExisting(): Map<string, Row> {
  const map = new Map<string, Row>();
  if (!existsSync(OUT)) return map;
  const lines = readFileSync(OUT, "utf8").split("\n").filter((l) => l.length > 0);
  for (const line of lines.slice(1)) {
    const cells = line.split("\t");
    const row = Object.fromEntries(COLUMNS.map((c, i) => [c, cells[i] ?? ""])) as Row;
    map.set(row.id, row);
  }
  return map;
}

function main(): void {
  const tmp = mkdtempSync(join(tmpdir(), "ft-parity-"));
  try {
    const tar = execFileSync("git", ["-C", ORIGINAL, "archive", PINNED], { maxBuffer: 1 << 30 });
    execFileSync("tar", ["-x", "-C", tmp], { input: tar });
    const files: string[] = [];
    walk(tmp, files);
    files.sort((a, b) => (relative(tmp, a) < relative(tmp, b) ? -1 : 1));

    const existing = readExisting();
    const rows: Row[] = [];
    const seen = new Set<string>();
    for (const abs of files) {
      const file = relative(tmp, abs);
      const cls = classify(file);
      const occurrences = new Map<string, number>();
      for (const t of collect(file, readFileSync(abs, "utf8"))) {
        const describe = t.describe.join(" › ");
        const key = `${file}\n${describe}\n${t.title}`;
        const n = (occurrences.get(key) ?? 0) + 1;
        occurrences.set(key, n);
        // A repeated title in the same describe gets its occurrence number mixed in, so ids stay unique and stable.
        const id = `T-${sha8(n === 1 ? key : `${key}\n#${n}`)}`;
        if (seen.has(id)) throw new Error(`id collision ${id}`);
        seen.add(id);
        const prev = existing.get(id);
        rows.push({
          id, file, describe: clean(describe), title: clean(t.title), form: t.form, class: cls,
          area: areaOf(file), swiftTarget: targetOf(file, cls),
          status: prev && prev.status !== "gone" ? prev.status : "todo",
          swiftTest: prev?.swiftTest ?? "", note: prev?.note ?? "",
        });
      }
    }
    const gone = [...existing.values()].filter((r) => !seen.has(r.id)).map((r) => ({ ...r, status: "gone" }));
    const all = [...rows, ...gone];
    writeFileSync(OUT, [COLUMNS.join("\t"), ...all.map((r) => COLUMNS.map((c) => r[c]).join("\t"))].join("\n") + "\n");

    const count = (key: "class" | "area"): string =>
      Object.entries(rows.reduce<Record<string, number>>((m, r) => ((m[r[key]] = (m[r[key]] ?? 0) + 1), m), {}))
        .sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, v]) => `  ${k.padEnd(22)} ${v}`).join("\n");
    console.log(`files: ${files.length}  cases: ${rows.length}  gone: ${gone.length}`);
    console.log(`by class:\n${count("class")}\nby area:\n${count("area")}`);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

main();
