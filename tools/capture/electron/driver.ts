// Drives the original Electron app (the reference build) through a capture scenario, with the
// reference's own Playwright, and writes the same files as the Swift app's `--automation` mode:
// <out>/<name>.png, <out>/<name>.json (geometry) and <out>/report.json.
//
// Usage: bun tools/capture/electron/driver.ts --scenario <file> --out <dir>
//          [--elements tools/capture/elements.json] [--reference <dir>] [--now <ISO local time>]
import { execFileSync } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, normalize, resolve } from "node:path";
import type { ElectronApplication, Page } from "playwright";

type ElementRef = string | { name: string; index?: number; text?: string };
type PrefValue = string | number | boolean | null | PrefValue[] | { [key: string]: PrefValue };
type Step =
  | { step: "window"; width: number; height: number }
  | { step: "prefs"; prefs: Record<string, PrefValue> }
  | { step: "open"; path: string }
  | { step: "select"; names: string[] }
  | { step: "key"; key: string; modifiers?: string[] }
  | { step: "type"; text: string }
  | { step: "command"; id: string }
  | { step: "wait"; ms: number }
  | { step: "snapshot"; name: string }
  | { step: "geometry"; name: string }
  | {
      step: "click";
      element: ElementRef;
      index?: number;
      text?: string;
      button?: "left" | "right";
      count?: number;
      modifiers?: string[];
      holdMs?: number;
    }
  | { step: "pick"; element: ElementRef; index?: number; text?: string; option: string }
  | { step: "menu"; path: string[] }
  | { step: "contextMenu"; element: ElementRef; index?: number; text?: string; choose?: string | string[] }
  | { step: "drag"; from: ElementRef; to: ElementRef; modifiers?: string[]; toEdge?: "top" | "bottom" }
  | { step: "expectSheet"; name: string }
  | { step: "sheetButton"; label: string }
  | { step: "newWindow" }
  | { step: "newTab" }
  | { step: "selectTab"; index: number }
  | { step: "selectWindow"; index?: number; title?: string }
  | {
      step: "fs";
      op: "create" | "write" | "rename" | "delete" | "chmod" | "lock" | "touch";
      path: string;
      contents?: string;
      directory?: boolean;
      append?: boolean;
      to?: string;
      mode?: string;
      locked?: boolean;
    }
  | { step: "expect"; element: ElementRef; text?: string; visible?: boolean; count?: number };

interface Scenario {
  name: string;
  root?: string;
  now?: string;
  steps: Step[];
}

interface ElementSpec {
  electron: { selector: string; textSelector?: string; textAttribute?: string };
  swift: string;
  first?: boolean;
  text?: boolean;
  geometry?: boolean;
}

type Status = "ok" | "partial" | "unsupported" | "failed" | "timeout";
interface Check {
  passed: boolean;
  detail: string;
}
interface Outcome {
  status: Status;
  message?: string;
  check?: Check;
}
interface Entry extends Outcome {
  index: number;
  step: string;
  milliseconds: number;
}

/// What the page finds for an element: its center, and how many there are.
interface Found {
  count: number;
  x?: number;
  y?: number;
  text?: string;
  height?: number;
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
const preferencesFile = join(here, "..", "preferences.json");
const cache = expandHome(process.env.FILETRAIL_PORT_CACHE ?? "~/Library/Caches/filetrail-port");
const referenceDir = argument("--reference") ?? join(cache, "reference", "electron");
const appDir = join(referenceDir, "apps", "desktop");
const fixtures = expandHome(process.env.FILETRAIL_FIXTURES ?? join(cache, "fixtures"));
const scratchRoot = process.env.FILETRAIL_SCENARIO_ROOT || undefined;

const scenario = JSON.parse(readFileSync(scenarioFile, "utf8")) as Scenario;
const elements = JSON.parse(readFileSync(elementsFile, "utf8")).elements as Record<string, ElementSpec>;
const preferenceKeys = JSON.parse(readFileSync(preferencesFile, "utf8")) as { keys: string[]; session: string[] };
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

function rootPath(): string {
  let base = expandHome(scratchRoot ?? scenario.root ?? "");
  if (!isAbsolute(base)) base = join(fixtures, base);
  return normalize(base).replace(/\/$/, "") || "/";
}

function resolvePath(path: string): string {
  const target = expandHome(path);
  return normalize(isAbsolute(target) ? target : resolve(rootPath(), target)).replace(/\/$/, "") || "/";
}

// The original's preference names (docs/port/inventory/app-shell-and-tests.md §2), plus the
// capture's `density` shorthand for the four compact switches.
function preferencesFrom(prefs: Record<string, PrefValue>): { values: Record<string, unknown>; unknown: string[] } {
  const values: Record<string, unknown> = {};
  const unknown: string[] = [];
  for (const [key, value] of Object.entries(prefs)) {
    if (key === "density") {
      const compact = value === "compact";
      values.compactListView = compact;
      values.compactDetailsView = compact;
      values.compactIconView = compact;
      values.compactTreeView = compact;
    } else if (preferenceKeys.keys.includes(key)) {
      values[key] = value;
    } else {
      unknown.push(key);
    }
  }
  return { values, unknown };
}

function elementRef(ref: ElementRef, siblings?: { index?: number; text?: string }) {
  if (typeof ref === "string") return { name: ref, index: siblings?.index, text: siblings?.text };
  return ref;
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

function modifierKeys(names: string[] | undefined): string[] {
  const keys = (names ?? []).map((m) => MODIFIERS[m.toLowerCase()]);
  if (keys.some((m) => !m)) throw new Error(`unknown modifier in ${names}`);
  return keys;
}

async function main() {
  const require = createRequire(join(appDir, "package.json"));
  const { _electron: electron } = require("playwright") as typeof import("playwright");
  const electronPath = require("electron") as unknown as string;
  if (!existsSync(join(appDir, "dist", "main"))) {
    throw new Error(`the reference app is not built at ${appDir} (run tools/reference/setup.sh)`);
  }

  // Preferences are seeded before launch, from the prefs steps that come before the first
  // step that needs the window; later ones go to the running app.
  // The window opens on the first open step's folder, as the Swift side's does.
  const seeded: Record<string, unknown> = {};
  for (const step of scenario.steps) {
    if (step.step === "prefs") Object.assign(seeded, preferencesFrom(step.prefs).values);
    else if (step.step !== "window") break;
  }
  const opening = scenario.steps.find((step) => step.step === "open");
  const firstOpen = opening?.step === "open" ? resolvePath(opening.path) : null;

  const userDataDir = mkdtempSync(join(tmpdir(), "filetrail-capture-"));
  writeFileSync(join(userDataDir, "app-state.json"), `${JSON.stringify({ preferences: seeded }, null, 2)}\n`);

  const args = [appDir, `--user-data-dir=${userDataDir}`, "--force-device-scale-factor=2"];
  if (firstOpen) args.push("--folder", firstOpen);
  const app: ElectronApplication = await electron.launch({
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
  // The window steps act on; window and tab steps change it.
  let page: Page = await app.firstWindow();
  try {
    if (now) await page.clock.resume();
    await page.locator("main.app-shell").waitFor({ timeout: 30_000 });
    if (firstOpen) await waitForFolder(firstOpen);
    await settle();

    for (const [offset, step] of scenario.steps.entries()) {
      const started = Date.now();
      let outcome: Outcome;
      try {
        outcome = await Promise.race([
          perform(step).then(async (result) => {
            await settle();
            return result;
          }),
          new Promise<Outcome>((resolveTimeout) =>
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
        ...(outcome.check ? { check: outcome.check } : {}),
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

  async function waitForFolder(path: string, target: Page = page) {
    const name = path === "/" ? null : basename(path);
    try {
      await target.waitForFunction(
        (expected) =>
          (expected === null || document.title === expected) &&
          document.querySelector(".content-loading") === null,
        name,
        { timeout: 20_000, polling: 100 },
      );
    } catch {
      throw new Error(`the window did not show ${path} (its title is "${await target.title()}")`);
    }
  }

  // Two frames and a quiet moment: React commits, layout, paint.
  async function settle() {
    await page
      .evaluate(
        () =>
          new Promise<void>((done) =>
            requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(done, 150))),
          ),
      )
      .catch(() => {});
  }

  // Polls a check in Node, not with the page's own waiting: animation frames stop while macOS
  // counts the window as hidden (see the original's e2e/fileOperations.spec.ts).
  async function waitUntil(check: () => Promise<boolean>, timeout = 5_000): Promise<boolean> {
    const end = Date.now() + timeout;
    for (;;) {
      if (await check().catch(() => false)) return true;
      if (Date.now() > end) return false;
      await new Promise((r) => setTimeout(r, 50));
    }
  }

  async function windowId(target: Page = page): Promise<number> {
    const window = await app.browserWindow(target);
    return window.evaluate((browserWindow) => browserWindow.id);
  }

  async function sendCommand(type: string) {
    const window = await app.browserWindow(page);
    await window.evaluate((browserWindow, commandType) => {
      browserWindow.webContents.send("filetrail:command", { type: commandType });
    }, type);
  }

  /// The explorer windows (not Settings, About or Help), in the order they opened.
  async function explorerPages(): Promise<Page[]> {
    const pages: Page[] = [];
    for (const candidate of app.windows()) {
      if (candidate.isClosed()) continue;
      const isExplorer = await candidate
        .evaluate(() => document.querySelector("main.app-shell") !== null)
        .catch(() => false);
      if (isExplorer) pages.push(candidate);
    }
    return pages;
  }

  /// Finds an element as the Swift side does: every match on screen, top to bottom then left to
  /// right, narrowed by its text; answers the picked one's center.
  async function find(ref: ElementRef, siblings?: { index?: number; text?: string }, target: Page = page) {
    const { name, index, text } = elementRef(ref, siblings);
    const spec = elements[name];
    if (!spec) throw new Error(`unknown element "${name}"`);
    const found = await target.evaluate(
      ({ selector, textSelector, textAttribute, text, index }) => {
        const textOf = (node: Element): string => {
          // A button drawn as an icon is named by its label (aria-label), not by text.
          if (textAttribute) return node.getAttribute(textAttribute) ?? "";
          const holder = textSelector ? (node.querySelector(textSelector) ?? node) : node;
          if (holder instanceof HTMLInputElement) return holder.value || holder.placeholder;
          if (holder instanceof HTMLSelectElement) return holder.selectedOptions[0]?.textContent?.trim() ?? "";
          // textContent, not innerText: a name is drawn as stem and extension spans, which
          // innerText splits onto two lines.
          return (holder.textContent ?? "").replace(/\s+/g, " ").trim();
        };
        const matches = Array.from(document.querySelectorAll(selector))
          .map((node) => ({ node, rect: node.getBoundingClientRect() }))
          // On screen: its center is in the window (a step acts at the center).
          .filter(({ rect }) => rect.width > 0 || rect.height > 0)
          .filter(({ rect }) => {
            const x = rect.x + rect.width / 2;
            const y = rect.y + rect.height / 2;
            return x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight;
          })
          .filter(({ node }) => text === undefined || textOf(node) === text)
          .sort((a, b) => a.rect.y - b.rect.y || a.rect.x - b.rect.x);
        const picked = matches[index ?? 0];
        if (!picked) return { count: matches.length };
        return {
          count: matches.length,
          x: picked.rect.x + picked.rect.width / 2,
          y: picked.rect.y + picked.rect.height / 2,
          height: picked.rect.height,
          text: textOf(picked.node),
        };
      },
      {
        selector: spec.electron.selector,
        textSelector: spec.electron.textSelector,
        textAttribute: spec.electron.textAttribute,
        text,
        index,
      },
    );
    const label = [name, text === undefined ? "" : `“${text}”`, index === undefined ? "" : `#${index}`]
      .filter(Boolean)
      .join(" ");
    return { found: found as Found, label };
  }

  /// The point a step acts on. An element scrolled out of its list is scrolled into view first, as
  /// a person would; the matches on screen are then counted again.
  async function at(
    ref: ElementRef,
    siblings?: { index?: number; text?: string },
    target: Page = page,
    edge?: "top" | "bottom",
  ) {
    let { found, label } = await find(ref, siblings, target);
    if (found.x === undefined && (await reveal(ref, siblings, target))) {
      ({ found, label } = await find(ref, siblings, target));
    }
    if (found.x === undefined || found.y === undefined || found.height === undefined) {
      throw new Error(found.count === 0 ? `no ${label} on screen` : `only ${found.count} of ${label}`);
    }
    const shift = edge === "top" ? -found.height / 4 : edge === "bottom" ? found.height / 4 : 0;
    return { x: found.x, y: found.y + shift, label };
  }

  async function reveal(ref: ElementRef, siblings: { index?: number; text?: string } | undefined, target: Page) {
    const { index, text, name } = elementRef(ref, siblings);
    const spec = elements[name];
    return target.evaluate(
      ({ selector, textSelector, textAttribute, text, index }) => {
        const textOf = (node: Element): string => {
          if (textAttribute) return node.getAttribute(textAttribute) ?? "";
          const holder = textSelector ? (node.querySelector(textSelector) ?? node) : node;
          if (holder instanceof HTMLInputElement) return holder.value || holder.placeholder;
          return (holder.textContent ?? "").replace(/\s+/g, " ").trim();
        };
        const matches = Array.from(document.querySelectorAll(selector))
          .filter((node) => text === undefined || textOf(node) === text)
          .filter((node) => node.getClientRects().length > 0);
        const node = matches[index ?? 0];
        if (!node) return false;
        node.scrollIntoView({ block: "center", inline: "nearest" });
        return true;
      },
      {
        selector: spec.electron.selector,
        textSelector: spec.electron.textSelector,
        textAttribute: spec.electron.textAttribute,
        text,
        index,
      },
    );
  }

  async function withModifiers<T>(names: string[] | undefined, action: () => Promise<T>): Promise<T> {
    const keys = modifierKeys(names);
    for (const key of keys) await page.keyboard.down(key);
    try {
      return await action();
    } finally {
      for (const key of keys.reverse()) await page.keyboard.up(key);
    }
  }

  async function chooseMenu(path: string[], target: Page = page): Promise<string | null> {
    const id = await windowId(target);
    return app.evaluate(
      ({ Menu, BrowserWindow }, { path, id }) => {
        const plain = (text: string) => text.replace(/(…|\.)+$/, "");
        let items = Menu.getApplicationMenu()?.items ?? [];
        let item: (typeof items)[number] | undefined;
        for (const [depth, label] of path.entries()) {
          item = items.find((i) => i.visible !== false && (i.label === label || plain(i.label) === plain(label)));
          if (!item && depth === 0 && label === "File Trail") item = items[0];
          if (!item) return `no menu item ${path.slice(0, depth + 1).join(" › ")}`;
          if (depth < path.length - 1) items = item.submenu?.items ?? [];
        }
        if (!item) return "empty menu path";
        if (!item.enabled) return `“${item.label}” is disabled`;
        const window = BrowserWindow.fromId(id) ?? undefined;
        // The menu sends a command to the window it is given, as a click with that window in front does.
        (item.click as (event: unknown, window?: unknown, contents?: unknown) => void)(
          {},
          window,
          window?.webContents,
        );
        return null;
      },
      { path, id },
    );
  }

  async function perform(step: Step): Promise<Outcome> {
    switch (step.step) {
      case "window": {
        const window = await app.browserWindow(page);
        await window.evaluate(
          (browserWindow, size) => {
            browserWindow.setContentSize(size.width, size.height);
          },
          { width: step.width, height: step.height },
        );
        await page.waitForFunction(
          (size) => window.innerWidth === size.width && window.innerHeight === size.height,
          { width: step.width, height: step.height },
          { timeout: 5_000 },
        );
        return { status: "ok" };
      }
      case "prefs": {
        const { values, unknown } = preferencesFrom(step.prefs);
        if (unknown.length) return { status: "failed", message: `not preferences of the original: ${unknown.join(", ")}` };
        // Before launch these were seeded.
        const index = scenario.steps.indexOf(step);
        const firstLive = scenario.steps.findIndex((s) => s.step !== "prefs" && s.step !== "window");
        if (firstLive === -1 || index < firstLive) return { status: "ok" };
        // Afterwards: what the whole app shares goes out as Settings sends it; the window's own
        // view goes through its commands; the rest of the window's session can only be seeded.
        const shared: Record<string, unknown> = {};
        const unsupported: string[] = [];
        for (const [key, value] of Object.entries(values)) {
          if (!preferenceKeys.session.includes(key)) shared[key] = value;
          else if (key === "viewMode") {
            const command = { icons: "viewAsIcons", details: "viewAsDetails", list: "viewAsList" }[String(value)];
            if (command) await sendCommand(command);
            else return { status: "failed", message: `viewMode ${value}` };
          } else unsupported.push(key);
        }
        if (Object.keys(shared).length) {
          await page.evaluate(
            (patch) =>
              (
                window as unknown as {
                  filetrail: { invoke(channel: string, payload: unknown): Promise<unknown> };
                }
              ).filetrail.invoke("app:updatePreferences", { preferences: patch }),
            shared,
          );
          const window = await app.browserWindow(page);
          await window.evaluate((browserWindow, patch) => {
            browserWindow.webContents.send("filetrail:preferencesChanged", patch);
          }, shared);
        }
        return unsupported.length
          ? { status: "partial", message: `window session keys only seeded before launch: ${unsupported.join(", ")}` }
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
        await page.keyboard.press([...modifierKeys(step.modifiers), key].join("+"));
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
      case "geometry":
        await dumpGeometry(step.name);
        return { status: "ok" };
      case "click": {
        const point = await at(step.element, step);
        const hold = step.holdMs ?? 0;
        await withModifiers(step.modifiers, async () => {
          if (hold > 0) {
            // A press held down (the Back button's history menu opens after 350 ms).
            await page.mouse.move(point.x, point.y);
            await page.mouse.down({ button: step.button ?? "left" });
            await page.waitForTimeout(hold);
            await page.mouse.up({ button: step.button ?? "left" });
          } else {
            await page.mouse.click(point.x, point.y, { button: step.button ?? "left", clickCount: step.count ?? 1 });
          }
        });
        return { status: "ok" };
      }
      case "pick": {
        // A pop-up (a <select>) set to one of its options by its text, as choosing it does.
        const point = await at(step.element, step);
        const picked = await page.evaluate(
          ({ x, y, option }) => {
            const node = document.elementFromPoint(x, y);
            const select =
              node instanceof HTMLSelectElement ? node : node?.closest("label, span")?.querySelector("select");
            if (!(select instanceof HTMLSelectElement)) return "not a pop-up";
            const choice = Array.from(select.options).find((o) => o.textContent?.trim() === option);
            if (!choice) return `no option “${option}”`;
            if (choice.disabled) return `“${option}” is disabled`;
            const setValue = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")?.set;
            setValue?.call(select, choice.value);
            select.dispatchEvent(new Event("input", { bubbles: true }));
            select.dispatchEvent(new Event("change", { bubbles: true }));
            return null;
          },
          { x: point.x, y: point.y, option: step.option },
        );
        return picked ? { status: "failed", message: picked } : { status: "ok" };
      }
      case "menu": {
        const problem = await chooseMenu(step.path);
        return problem ? { status: "failed", message: problem } : { status: "ok" };
      }
      case "contextMenu": {
        const point = await at(step.element, step);
        await page.mouse.click(point.x, point.y, { button: "right" });
        if (!(await waitUntil(() => page.evaluate(() => document.querySelector(".context-menu") !== null)))) {
          return { status: "failed", message: `no context menu on ${point.label}` };
        }
        const choose = step.choose === undefined ? [] : Array.isArray(step.choose) ? step.choose : [step.choose];
        for (const [depth, label] of choose.entries()) {
          const scope = depth === 0 ? ".context-menu" : ".context-submenu";
          const item = await page.evaluate(
            ({ scope, label }) => {
              const plain = (text: string) => text.replace(/(…|\.)+$/, "");
              const items = Array.from(document.querySelectorAll(`${scope} .context-menu-item`));
              const node = items.find((n) => {
                const text = (n.querySelector(".context-menu-item-label")?.textContent ?? "").trim();
                return text === label || plain(text) === plain(label);
              });
              if (!node) return { error: `no item “${label}”` };
              if (node.getAttribute("aria-disabled") === "true") return { error: `“${label}” is disabled` };
              const rect = node.getBoundingClientRect();
              return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
            },
            { scope, label },
          );
          if ("error" in item) return { status: "failed", message: item.error };
          if (depth < choose.length - 1) {
            await page.mouse.move(item.x, item.y);
            if (!(await waitUntil(() => page.evaluate(() => document.querySelector(".context-submenu") !== null)))) {
              return { status: "failed", message: `“${label}” opened no submenu` };
            }
          } else {
            await page.mouse.click(item.x, item.y);
          }
        }
        return { status: "ok" };
      }
      case "drag":
        return drag(step.from, step.to, step.modifiers, step.toEdge);
      case "expectSheet": {
        const shown = await waitUntil(async () => (await find(step.name)).found.count > 0);
        return shown ? { status: "ok" } : { status: "failed", message: `no ${step.name} shown` };
      }
      case "sheetButton": {
        const button = await page.evaluate((label) => {
          const scopes = Array.from(
            document.querySelectorAll("dialog[open], .go-to-folder-dialog, .copy-paste-sheet, [role=dialog]"),
          );
          const name = (b: Element) =>
            ((b as HTMLElement).innerText ?? "").trim() || b.getAttribute("aria-label") || "";
          for (const scope of [...scopes.reverse(), document.body]) {
            const node = Array.from(scope.querySelectorAll("button")).find(
              (b) => name(b) === label && !(b as HTMLButtonElement).disabled && b.getBoundingClientRect().width > 0,
            );
            if (node) {
              const rect = node.getBoundingClientRect();
              return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
            }
          }
          return null;
        }, step.label);
        if (!button) return { status: "failed", message: `no enabled button “${step.label}”` };
        await page.mouse.click(button.x, button.y);
        return { status: "ok" };
      }
      case "newWindow": {
        const opened = app.waitForEvent("window", { timeout: 15_000 });
        const id = await windowId();
        await app.evaluate(
          ({ Menu, BrowserWindow }, id) => {
            const item = Menu.getApplicationMenu()?.getMenuItemById("newWindow");
            const window = BrowserWindow.fromId(id) ?? undefined;
            (item?.click as (event: unknown, window?: unknown, contents?: unknown) => void)?.(
              {},
              window,
              window?.webContents,
            );
          },
          id,
        );
        const next = await opened;
        const ready = await waitUntil(
          () => next.evaluate(() => document.querySelector("main.app-shell .content-viewport") !== null),
          30_000,
        );
        if (!ready) return { status: "failed", message: "the new window did not show a folder" };
        page = next;
        await waitUntil(() => page.evaluate(() => document.querySelector(".content-loading") === null), 20_000);
        return { status: "ok" };
      }
      case "newTab": {
        const tabs = () => page.evaluate(() => document.querySelectorAll('[role="tab"]').length);
        const before = await tabs();
        await sendCommand("newTab");
        const added = await waitUntil(async () => (await tabs()) > Math.max(1, before));
        return added ? { status: "ok" } : { status: "failed", message: "no tab was added" };
      }
      case "selectTab": {
        const tab = await find("tab", { index: step.index });
        if (tab.found.x === undefined || tab.found.y === undefined) {
          if (step.index === 0 && tab.found.count === 0) return { status: "ok" };
          return { status: "failed", message: `no tab ${step.index} of ${tab.found.count}` };
        }
        await page.mouse.click(tab.found.x, tab.found.y);
        return { status: "ok" };
      }
      case "selectWindow": {
        let picked: Page | undefined;
        const found = await waitUntil(async () => {
          if (step.index !== undefined) picked = (await explorerPages())[step.index];
          else picked = undefined;
          if (step.title !== undefined) {
            if (picked) return (await picked.title()) === step.title;
            for (const candidate of app.windows()) {
              if (!candidate.isClosed() && (await candidate.title()) === step.title) {
                picked = candidate;
                return true;
              }
            }
            return false;
          }
          return picked !== undefined;
        });
        if (!found || !picked) {
          return { status: "failed", message: `no window ${step.title ? `titled “${step.title}”` : step.index}` };
        }
        page = picked;
        await page.waitForLoadState("domcontentloaded");
        return { status: "ok" };
      }
      case "fs":
        return fileOp(step);
      case "expect": {
        const ref = elementRef(step.element);
        const spec = elements[ref.name];
        if (!spec) return { status: "failed", message: `unknown element "${ref.name}"` };
        const { found, label } = await find(ref);
        const picked = found.x !== undefined;
        const problems: string[] = [];
        const seen: string[] = [];
        if (step.count !== undefined) {
          seen.push(`count ${found.count}`);
          if (found.count !== step.count) problems.push(`count ${found.count}, expected ${step.count}`);
        }
        if (step.visible !== undefined) {
          seen.push(picked ? "visible" : "hidden");
          if (step.visible !== picked) problems.push(step.visible ? "not shown" : "shown");
        }
        if (step.text !== undefined) {
          seen.push(`text “${found.text ?? ""}”`);
          if (found.text !== step.text) {
            problems.push(picked ? `text “${found.text}”, expected “${step.text}”` : `no ${label}`);
          }
        }
        return {
          status: "ok",
          check: {
            passed: problems.length === 0,
            detail: `${label}: ${(problems.length ? problems : seen).join(problems.length ? "; " : ", ")}`,
          },
        };
      }
      default:
        return { status: "failed", message: `unknown step ${(step as { step: string }).step}` };
    }
  }

  // A drag of the app's items starts a native drag session, which a test can't drive. It is played
  // as e2e/dragIn.spec.ts plays a drag from another app: the items go on the drag pasteboard, and
  // the target is sent the drag's events, as Chromium sends them.
  async function drag(
    from: ElementRef,
    to: ElementRef,
    modifiers?: string[],
    edge?: "top" | "bottom",
  ): Promise<Outcome> {
    const source = await at(from);
    const items = await page.evaluate(
      ({ x, y }) => {
        const node = document.elementFromPoint(x, y)?.closest("[data-selectable-entry-path]");
        const path = node?.getAttribute("data-selectable-entry-path");
        if (!path) return [];
        if (node?.getAttribute("aria-selected") !== "true") return [path];
        return Array.from(document.querySelectorAll('[data-selectable-entry-path][aria-selected="true"]'))
          .map((n) => n.getAttribute("data-selectable-entry-path") ?? "")
          .filter((p, i, all) => p && all.indexOf(p) === i);
      },
      { x: source.x, y: source.y },
    );
    if (items.length === 0) {
      const target = await at(to, undefined, page, edge);
      // An HTML drag inside the page (a favorite row): its events are sent with one DataTransfer
      // from the drag start to the drop, as Chromium sends them, a frame apart so the page can
      // take in each one (it keeps what is being dragged in its state).
      const fire = (type: string, point: { x: number; y: number }, onSource: boolean) =>
        page.evaluate(
          ({ type, point, onSource, from }) => {
            const state = window as unknown as { __captureDrag?: DataTransfer };
            if (type === "dragstart") state.__captureDrag = new DataTransfer();
            const dataTransfer = state.__captureDrag;
            const node = onSource
              ? document.elementFromPoint(from.x, from.y)?.closest('[draggable="true"]')
              : document.elementFromPoint(point.x, point.y);
            if (!node || !dataTransfer) return "missing";
            const event = new DragEvent(type, {
              bubbles: true,
              cancelable: true,
              clientX: point.x,
              clientY: point.y,
              dataTransfer,
            });
            node.dispatchEvent(event);
            if (type === "dragend") state.__captureDrag = undefined;
            return event.defaultPrevented ? "taken" : "ignored";
          },
          { type, point, onSource, from: { x: source.x, y: source.y } },
        );
      const draggable = await page.evaluate(
        ({ x, y }) => document.elementFromPoint(x, y)?.closest('[draggable="true"]') != null,
        { x: source.x, y: source.y },
      );
      if (draggable) {
        const to = { x: target.x, y: target.y };
        await fire("dragstart", { x: source.x, y: source.y }, true);
        await settle();
        await fire("dragenter", to, false);
        let over = await fire("dragover", to, false);
        await settle();
        over = await fire("dragover", to, false);
        if (over === "taken") await fire("drop", to, false);
        await fire("dragend", to, true);
        return over === "taken"
          ? { status: "ok", message: "HTML drag events" }
          : { status: "failed", message: "the target refused the drop" };
      }
      // Not a file and not an HTML drag: a drag the page runs itself with the pointer (toolbar items).
      await withModifiers(modifiers, async () => {
        await page.mouse.move(source.x, source.y);
        await page.mouse.down();
        const steps = 12;
        for (let step = 1; step <= steps; step += 1) {
          await page.mouse.move(
            source.x + ((target.x - source.x) * step) / steps,
            source.y + ((target.y - source.y) * step) / steps,
          );
          await page.waitForTimeout(16);
        }
        await page.waitForTimeout(100);
        await page.mouse.up();
      });
      return { status: "ok", message: "pointer drag" };
    }
    // The target may be in another window.
    let targetPage: Page | undefined;
    let point: { x: number; y: number; label: string } | undefined;
    for (const candidate of [page, ...(await explorerPages()).filter((p) => p !== page)]) {
      try {
        point = await at(to, undefined, candidate);
        targetPage = candidate;
        break;
      } catch {}
    }
    if (!targetPage || !point) return { status: "failed", message: `no ${elementRef(to).name} in any window` };
    const urls = items.map((path) => `$.NSURL.fileURLWithPath(${JSON.stringify(path)})`).join(",");
    execFileSync("osascript", [
      "-l",
      "JavaScript",
      "-e",
      `ObjC.import("AppKit");
       const pasteboard = $.NSPasteboard.pasteboardWithName($.NSPasteboardNameDrag);
       pasteboard.clearContents;
       pasteboard.writeObjects($([${urls}]));`,
    ]);
    const keys = new Set(modifierKeys(modifiers));
    const send = (type: "dragenter" | "dragover" | "drop") =>
      (targetPage as Page).evaluate(
        ({ type, x, y, alt, meta, shift, ctrl }) => {
          const target = document.elementFromPoint(x, y);
          if (!target) throw new Error("nothing at the drop point");
          const dataTransfer = { types: ["Files"], effectAllowed: "all", dropEffect: "none", files: [] };
          const event = new DragEvent(type, {
            bubbles: true,
            cancelable: true,
            clientX: x,
            clientY: y,
            altKey: alt,
            metaKey: meta,
            shiftKey: shift,
            ctrlKey: ctrl,
          });
          Object.defineProperty(event, "dataTransfer", { value: dataTransfer });
          target.dispatchEvent(event);
          return dataTransfer.dropEffect;
        },
        {
          type,
          x: (point as { x: number }).x,
          y: (point as { y: number }).y,
          alt: keys.has("Alt"),
          meta: keys.has("Meta"),
          shift: keys.has("Shift"),
          ctrl: keys.has("Control"),
        },
      );
    await send("dragenter");
    let cursor = await send("dragover");
    const end = Date.now() + 5_000;
    while (cursor === "none" && Date.now() < end) {
      await new Promise((r) => setTimeout(r, 50));
      cursor = await send("dragover");
    }
    if (cursor === "none") return { status: "failed", message: `the window refused the drop at ${point.label}` };
    await send("drop");
    page = targetPage;
    return { status: "ok", message: `played as a drag of files from another app (${cursor})` };
  }

  // Changes the fixture from outside the app. Only a scratch copy (setup.scratch) is changed.
  function fileOp(step: Extract<Step, { step: "fs" }>): Outcome {
    if (!scratchRoot) return { status: "failed", message: "fs steps change only a scratch copy: give the scenario setup.scratch" };
    const root = rootPath();
    const inside = (path: string) => {
      const full = resolvePath(path);
      if (!full.startsWith(`${root}/`)) throw new Error(`${path} is outside the scenario's folder`);
      return full;
    };
    const stamp = (path: string) => {
      if (now) utimesSync(path, new Date(now), new Date(now));
    };
    const path = inside(step.path);
    switch (step.op) {
      case "create":
        if (existsSync(path)) throw new Error(`${step.path} already exists`);
        if (step.directory) mkdirSync(path);
        else writeFileSync(path, step.contents ?? "", { flag: "wx" });
        stamp(path);
        break;
      case "write":
        if (step.append) appendFileSync(path, step.contents ?? "");
        else writeFileSync(path, step.contents ?? "");
        stamp(path);
        break;
      case "rename": {
        if (!step.to) throw new Error("missing to");
        const target = inside(step.to);
        if (existsSync(target)) throw new Error(`${step.to} already exists`);
        renameSync(path, target);
        break;
      }
      case "delete":
        rmSync(path, { recursive: true });
        break;
      case "chmod":
        if (!step.mode || !/^[0-7]{3,4}$/.test(step.mode)) throw new Error("mode must be octal, such as 644");
        chmodSync(path, Number.parseInt(step.mode, 8));
        break;
      case "lock":
        execFileSync("chflags", [step.locked === false ? "nouchg" : "uchg", path]);
        break;
      case "touch":
        // Dates an item to the scenario's clock: a folder a write just changed would otherwise
        // show today's real time in the capture.
        if (!existsSync(path)) throw new Error(`${step.path} does not exist`);
        if (now) utimesSync(path, new Date(now), new Date(now));
        else utimesSync(path, new Date(), new Date());
        break;
      default:
        return { status: "failed", message: `unknown op ${(step as { op: string }).op}` };
    }
    return { status: "ok" };
  }

  async function dumpGeometry(name: string) {
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
            const textNode = spec.textSelector ? (node.querySelector(spec.textSelector) ?? node) : node;
            const string =
              textNode instanceof HTMLInputElement
                ? textNode.value || textNode.placeholder
                : ((textNode as HTMLElement).innerText?.trim() ?? "");
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
        // Elements named only for steps to act on are not compared.
        specs: Object.values(elements)
          .filter((spec) => spec.geometry !== false)
          .map((spec) => ({
            id: spec.swift,
            selector: spec.electron.selector,
            textSelector: spec.electron.textSelector,
            text: spec.text === true,
          })),
        name,
      },
    );
    writeFileSync(join(outDir as string, `${name}.json`), `${JSON.stringify(dump, null, 2)}\n`);
  }
}

main().then(
  () => process.exit(0),
  (error) => {
    report.error = String(error instanceof Error ? (error.stack ?? error.message) : error);
    writeReport();
    console.error(`driver: ${report.error.split("\n")[0]}`);
    process.exit(1);
  },
);
