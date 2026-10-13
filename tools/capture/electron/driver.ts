// Drives the original Electron app (the reference build) through a capture scenario, with the
// reference's own Playwright, and writes the same files as the Swift app's `--automation` mode:
// <out>/<name>.png, <out>/<name>.json (geometry) and <out>/report.json.
//
// Usage: bun tools/capture/electron/driver.ts --scenario <file> --out <dir>
//          [--elements tools/capture/elements.json] [--reference <dir>] [--now <ISO local time>]
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, normalize, resolve } from "node:path";

type Step =
  | { step: "window"; width: number; height: number }
  | { step: "prefs"; prefs: Record<string, string | number | boolean> }
  | { step: "open"; path: string }
  | { step: "select"; names: string[] }
  | { step: "key"; key: string; modifiers?: string[] }
  | { step: "type"; text: string }
  | { step: "command"; id: string }
  | { step: "wait"; ms: number }
  | { step: "snapshot"; name: string }
  | { step: "geometry"; name: string };

interface Scenario {
  name: string;
  root?: string;
  now?: string;
  steps: Step[];
}

interface ElementSpec {
  electron: { selector: string; textSelector?: string };
  swift: string;
  first?: boolean;
  text?: boolean;
}

type Status = "ok" | "partial" | "unsupported" | "failed" | "timeout";
interface Entry {
  index: number;
  step: string;
  status: Status;
  message?: string;
  milliseconds: number;
}

const STEP_TIMEOUT_MS = 30_000;

function argument(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function expandHome(path: string): string {
  if (path === "~") return homedir();
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

const scenarioFile = argument("--scenario");
const outDir = argument("--out");
if (!scenarioFile || !outDir) {
  console.error("usage: driver.ts --scenario <file> --out <dir> [--elements <file>] [--reference <dir>]");
  process.exit(2);
}
const here = dirname(new URL(import.meta.url).pathname);
const elementsFile = argument("--elements") ?? join(here, "..", "elements.json");
const cache = expandHome(process.env.FILETRAIL_PORT_CACHE ?? "~/Library/Caches/filetrail-port");
const referenceDir = argument("--reference") ?? join(cache, "reference", "electron");
const appDir = join(referenceDir, "apps", "desktop");
const fixtures = expandHome(process.env.FILETRAIL_FIXTURES ?? join(cache, "fixtures"));

const scenario = JSON.parse(readFileSync(scenarioFile, "utf8")) as Scenario;
const elements = JSON.parse(readFileSync(elementsFile, "utf8")).elements as Record<string, ElementSpec>;
const now = argument("--now") ?? process.env.FILETRAIL_NOW ?? scenario.now;
mkdirSync(outDir, { recursive: true });

const report: { scenario: string; side: string; steps: Entry[]; error?: string } = {
  scenario: scenario.name,
  side: "electron",
  steps: [],
};
function writeReport() {
  writeFileSync(join(outDir as string, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
}

function resolvePath(path: string): string {
  let base = expandHome(scenario.root ?? "");
  if (!isAbsolute(base)) base = join(fixtures, base);
  const target = expandHome(path);
  return normalize(isAbsolute(target) ? target : resolve(base, target)).replace(/\/$/, "") || "/";
}

// The original's preference names (docs/port/inventory/app-shell-and-tests.md §2).
function preferencesFrom(prefs: Record<string, string | number | boolean>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(prefs)) {
    if (key === "density") {
      const compact = value === "compact";
      out.compactListView = compact;
      out.compactDetailsView = compact;
      out.compactIconView = compact;
      out.compactTreeView = compact;
    } else {
      out[key] = value;
    }
  }
  return out;
}

const DOM_KEYS: Record<string, string> = { Return: "Enter", Space: " " };
const MODIFIERS: Record<string, string> = {
  cmd: "Meta",
  command: "Meta",
  meta: "Meta",
  shift: "Shift",
  option: "Alt",
  alt: "Alt",
  ctrl: "Control",
  control: "Control",
};

async function main() {
  const require = createRequire(join(appDir, "package.json"));
  const { _electron: electron } = require("playwright") as typeof import("playwright");
  const electronPath = require("electron") as unknown as string;
  if (!existsSync(join(appDir, "dist", "main"))) {
    throw new Error(`the reference app is not built at ${appDir} (run tools/reference/setup.sh)`);
  }

  // Preferences are seeded before launch, from the prefs steps that come before the first
  // step that needs the window; later ones go through commands where the original has one.
  const seeded: Record<string, unknown> = {};
  let firstOpen: string | null = null;
  for (const step of scenario.steps) {
    if (step.step === "prefs") Object.assign(seeded, preferencesFrom(step.prefs));
    else if (step.step === "open") {
      firstOpen = resolvePath(step.path);
      break;
    } else if (step.step !== "window") break;
  }

  const userDataDir = mkdtempSync(join(tmpdir(), "filetrail-capture-"));
  writeFileSync(
    join(userDataDir, "app-state.json"),
    `${JSON.stringify({ preferences: seeded }, null, 2)}\n`,
  );

  const args = [appDir, `--user-data-dir=${userDataDir}`, "--force-device-scale-factor=2"];
  if (firstOpen) args.push("--folder", firstOpen);
  const app = await electron.launch({
    executablePath: electronPath,
    args,
    cwd: appDir,
    env: { ...process.env, ...(now ? { FILETRAIL_NOW: now } : {}) } as Record<string, string>,
  });

  // The clock goes in before the window's page loads (the app opens it once it has started), so
  // the first listing is drawn on it. It then runs on from that instant, as FILETRAIL_NOW does.
  if (now) {
    await app.context().clock.install({ time: new Date(now) });
    await app.context().clock.resume();
  }
  const page = await app.firstWindow();
  try {
    if (now) await page.clock.resume();
    await page.locator("main.app-shell").waitFor({ timeout: 30_000 });
    if (firstOpen) await waitForFolder(firstOpen);
    await settle();

    for (const [offset, step] of scenario.steps.entries()) {
      const started = Date.now();
      let outcome: { status: Status; message?: string };
      try {
        outcome = await Promise.race([
          perform(step).then(async (result) => {
            await settle();
            return result;
          }),
          new Promise<{ status: Status; message: string }>((resolveTimeout) =>
            setTimeout(
              () => resolveTimeout({ status: "timeout", message: "did not finish within 30 s" }),
              STEP_TIMEOUT_MS,
            ),
          ),
        ]);
      } catch (error) {
        outcome = { status: "failed", message: String(error instanceof Error ? error.message : error).split("\n")[0] };
      }
      report.steps.push({
        index: offset + 1,
        step: step.step,
        status: outcome.status,
        ...(outcome.message ? { message: outcome.message } : {}),
        milliseconds: Date.now() - started,
      });
      writeReport();
    }
  } finally {
    writeReport();
    await Promise.race([app.close(), new Promise((r) => setTimeout(r, 15_000))]);
    try {
      app.process().kill("SIGKILL");
    } catch {}
    rmSync(userDataDir, { recursive: true, force: true });
  }

  async function waitForFolder(path: string) {
    const name = path === "/" ? null : basename(path);
    try {
      await page.waitForFunction(
        (expected) =>
          (expected === null || document.title === expected) &&
          document.querySelector(".content-loading") === null,
        name,
        { timeout: 20_000, polling: 100 },
      );
    } catch {
      throw new Error(`the window did not show ${path} (its title is "${await page.title()}")`);
    }
  }

  // Two frames and a quiet moment: React commits, layout, paint.
  async function settle() {
    await page.evaluate(
      () =>
        new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(done, 150))),
        ),
    );
  }

  async function sendCommand(type: string) {
    const window = await app.browserWindow(page);
    await window.evaluate((browserWindow, commandType) => {
      browserWindow.webContents.send("filetrail:command", { type: commandType });
    }, type);
  }

  async function perform(step: Step): Promise<{ status: Status; message?: string }> {
    switch (step.step) {
      case "window": {
        const window = await app.browserWindow(page);
        await window.evaluate((browserWindow, size) => {
          browserWindow.setContentSize(size.width, size.height);
        }, { width: step.width, height: step.height });
        await page.waitForFunction(
          (size) => window.innerWidth === size.width && window.innerHeight === size.height,
          { width: step.width, height: step.height },
          { timeout: 5_000 },
        );
        return { status: "ok" };
      }
      case "prefs": {
        // Before launch these were seeded; afterwards only the view and sort have commands.
        const index = scenario.steps.indexOf(step);
        const firstLive = scenario.steps.findIndex((s) => s.step !== "prefs" && s.step !== "window");
        if (firstLive === -1 || index < firstLive) return { status: "ok" };
        const unsupported: string[] = [];
        for (const [key, value] of Object.entries(step.prefs)) {
          if (key === "viewMode") {
            const command = { icons: "viewAsIcons", details: "viewAsDetails", list: "viewAsList" }[
              String(value)
            ];
            if (command) await sendCommand(command);
            else unsupported.push(`${key} ${value}`);
          } else {
            unsupported.push(key);
          }
        }
        return unsupported.length
          ? { status: "partial", message: `unsupported after launch: ${unsupported.join(", ")}` }
          : { status: "ok" };
      }
      case "open": {
        const path = resolvePath(step.path);
        const name = path === "/" ? null : basename(path);
        if (name !== null && (await page.title()) === name) return { status: "ok" };
        // The original's own Go to Folder sheet.
        await sendCommand("openLocationSheet");
        const input = page.locator(".go-to-folder-input");
        await input.waitFor({ timeout: 5_000 });
        await input.fill(path);
        for (let attempt = 0; attempt < 3; attempt += 1) {
          await input.press("Enter");
          try {
            await page.locator(".go-to-folder-dialog").waitFor({ state: "detached", timeout: 2_000 });
            break;
          } catch {}
        }
        await waitForFolder(path);
        return { status: "ok" };
      }
      case "select": {
        const folder = await page.evaluate(() => {
          const row = document.querySelector("[data-selectable-entry-path]");
          const path = row?.getAttribute("data-selectable-entry-path") ?? "";
          return path.slice(0, path.lastIndexOf("/"));
        });
        const missing: string[] = [];
        for (const [index, name] of step.names.entries()) {
          const target = page.locator(`[data-selectable-entry-path=${JSON.stringify(`${folder}/${name}`)}]`).first();
          if ((await target.count()) === 0) {
            missing.push(name);
            continue;
          }
          await target.click({ modifiers: index === 0 ? [] : ["Meta"] });
        }
        return missing.length ? { status: "failed", message: `not found: ${missing.join(", ")}` } : { status: "ok" };
      }
      case "key": {
        const key = DOM_KEYS[step.key] ?? step.key;
        const modifiers = (step.modifiers ?? []).map((m) => MODIFIERS[m.toLowerCase()]);
        if (modifiers.some((m) => !m)) return { status: "failed", message: `unknown modifier in ${step.modifiers}` };
        await page.keyboard.press([...modifiers, key].join("+"));
        return { status: "ok" };
      }
      case "type":
        await page.keyboard.type(step.text);
        return { status: "ok" };
      case "command":
        await sendCommand(step.id);
        return { status: "ok" };
      case "wait":
        await page.waitForTimeout(step.ms);
        return { status: "ok" };
      case "snapshot":
        await page.screenshot({ path: join(outDir as string, `${step.name}.png`), scale: "device" });
        return { status: "ok" };
      case "geometry": {
        const dump = await page.evaluate(
          ({ specs, name }) => {
            function hex(color: string): string | undefined {
              const match = color.match(/rgba?\(([^)]+)\)/);
              if (!match) return undefined;
              const parts = match[1].split(/[\s,/]+/).filter(Boolean).map(Number);
              const [r, g, b] = parts;
              const a = parts.length > 3 ? parts[3] : 1;
              const byte = (v: number) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0");
              const rgb = `#${byte(r)}${byte(g)}${byte(b)}`;
              return a >= 0.999 ? rgb : rgb + byte(a * 255);
            }
            const round = (v: number) => Math.round(v * 100) / 100;
            const elements: unknown[] = [];
            for (const spec of specs) {
              for (const node of Array.from(document.querySelectorAll(spec.selector))) {
                const rect = node.getBoundingClientRect();
                if (rect.width === 0 && rect.height === 0) continue;
                // Scrolled out of the window: not on screen to compare.
                if (rect.bottom <= 0 || rect.top >= window.innerHeight) continue;
                if (rect.right <= 0 || rect.left >= window.innerWidth) continue;
                const element: Record<string, unknown> = {
                  id: spec.id,
                  frame: { x: round(rect.x), y: round(rect.y), width: round(rect.width), height: round(rect.height) },
                };
                if (!spec.text) {
                  elements.push(element);
                  continue;
                }
                const textNode = spec.textSelector ? node.querySelector(spec.textSelector) ?? node : node;
                const string =
                  textNode instanceof HTMLInputElement
                    ? textNode.value || textNode.placeholder
                    : (textNode as HTMLElement).innerText?.trim() ?? "";
                if (string) {
                  const style = getComputedStyle(textNode);
                  element.text = {
                    string,
                    fontSize: Number.parseFloat(style.fontSize),
                    fontWeight: Number.parseInt(style.fontWeight, 10),
                    color: hex(style.color),
                  };
                }
                elements.push(element);
              }
            }
            return {
              format: "filetrail-geometry/1",
              side: "electron",
              name,
              window: { width: window.innerWidth, height: window.innerHeight },
              elements,
            };
          },
          {
            specs: Object.values(elements).map((spec) => ({
              id: spec.swift,
              selector: spec.electron.selector,
              textSelector: spec.electron.textSelector,
              text: spec.text === true,
            })),
            name: step.name,
          },
        );
        writeFileSync(join(outDir as string, `${step.name}.json`), `${JSON.stringify(dump, null, 2)}\n`);
        return { status: "ok" };
      }
      default:
        return { status: "failed", message: `unknown step ${(step as { step: string }).step}` };
    }
  }
}

main().then(
  () => process.exit(0),
  (error) => {
    report.error = String(error instanceof Error ? error.stack ?? error.message : error);
    writeReport();
    console.error(`driver: ${report.error.split("\n")[0]}`);
    process.exit(1);
  },
);
