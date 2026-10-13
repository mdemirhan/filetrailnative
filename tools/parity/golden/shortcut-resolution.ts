// resolveShortcuts and what is built on it (apps/desktop/src/shared/shortcuts.ts).
// Input: { overrides, probes, assignments, events }. overrides is any JSON as it could be saved; probes are shortcut
// texts; assignments are { id, shortcut, slot } tried on the resolved keys; events are key presses.
// Output: { bindings, commandByShortcut, sanitized, probes, assignments, events }:
//   bindings: every command's keys; commandByShortcut: [shortcut, command] in the map's order; sanitized: the
//   overrides as they would be saved; probes: what each text is (normalized, refusal, ...); assignments: the check,
//   and the overrides after assigning, removing and resetting; events: the shortcut each press spells.
// Zoom In, Zoom Out and Actual Size are not in the Swift table (DEVIATIONS D-005): their ids are left out of the input
// and the output.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Shortcuts = Record<string, any>;

export const seed = 0x5c0a1de5;

const ZOOM = new Set(["zoomIn", "zoomOut", "resetZoom"]);

const KEY_FORMS = [
  "Cmd+K", "cmd+k", "Command+K", "CommandOrControl+K", "Ctrl+K", "Control+Shift+K", "Cmd+Option+K", "Cmd+Alt+K",
  "Cmd+Shift+Option+Ctrl+K", "Shift+Cmd+K", "Option+Cmd+J", "Cmd+1", "Cmd+2", "Cmd+0", "Cmd+-", "Cmd+=", "Cmd+Plus",
  "Cmd++", "Cmd+[", "Cmd+]", "Cmd+\\", "Cmd+;", "Cmd+'", "Cmd+,", "Cmd+.", "Cmd+/", "Cmd+`", "Cmd+Shift+/", "F1",
  "F2", "f5", "F12", "F13", "F20", "F21", "Cmd+F3", "Ctrl+F4", "Space", "Cmd+Space", "Ctrl+Space", "Shift+Space",
  "Up", "Down", "Left", "Right", "Cmd+Up", "Cmd+Down", "Cmd+Left", "Cmd+Right", "Ctrl+Up", "Ctrl+Left",
  "Option+Left", "Shift+Left", "Home", "End", "PageUp", "PageDown", "Cmd+Home", "Tab", "Cmd+Tab", "Ctrl+Tab",
  "Ctrl+Shift+Tab", "Return", "Enter", "Cmd+Enter", "Esc", "Escape", "Cmd+Escape", "Backspace", "Delete",
  "Cmd+Backspace", "Cmd+Shift+Backspace", "Cmd+Delete", "?", "Shift+?", "Cmd+?", "A", "a", "z", "5", "Shift+A",
  "Option+A", "Ctrl+A", "Ctrl+D", "Ctrl+U", "Ctrl+Cmd+F", "Ctrl+Cmd+S", "Cmd+Z", "Cmd+Shift+Z", "Cmd+X", "Cmd+C",
  "Cmd+V", "Cmd+A", "Cmd+Q", "Cmd+W", "Cmd+Shift+W", "Cmd+M", "Cmd+H", "Cmd+Option+H", "Cmd+,", "Cmd+Shift+3",
  "Cmd+Shift+4", "Cmd+Option+D", "Cmd+Option+Esc", "Cmd+Option+Space", "Ctrl+Cmd+Q", "Cmd+Shift+Q", "F11", "Cmd+F11",
  "Cmd+N", "Cmd+T", "Cmd+Shift+T", "Cmd+R", "Cmd+F", "Cmd+I", "Cmd+O", "Cmd+E", "Cmd+D", "Cmd+Shift+G", "Cmd+Shift+.",
  "Cmd+Shift+M", "Cmd+Shift+N", "Cmd+Option+C", "Cmd+Option+T", "Cmd+Shift+[", "Cmd+Shift+]", "Cmd+Shift+H",
  "Cmd+Shift+R", "Cmd+Shift+E", "Cmd+Shift+F", "Cmd+Shift+I", "Cmd+3", " Cmd + K ", "Cmd+ K", "Cmd +K", "cmd+shift+k",
  "CTRL+CMD+S", "Cmd+K+K", "Cmd+Shift", "Cmd+", "+", "++", "+A", "Cmd+Meta+K", "Super+K", "", " ", "Cmd+Space+K",
  "Cmd+ñ", "Cmd+É", "Cmd+K", "Cmd+日", "Cmd+Ctrl+Ctrl+K", "constructor+K", "Cmd+constructor+K", "__proto__+K",
  "toString+K", "Cmd+Pageup", "Cmd+pagedown", "cmd+PLUS", "Cmd+up", "Cmd+EsC", "Cmd+F0", "Cmd+F01", "Cmd+F100",
];

const JUNK: unknown[] = [null, 0, 1, -1, 1.5, "", "Cmd+K", true, false, {}, [], [null], [[]], [1, "Cmd+K"], {}, "x"];

const EVENT_KEYS = [
  "a", "A", "z", "k", "K", "1", "0", "9", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`", "?", "!", "@", "#",
  "+", "_", "{", "}", ":", '"', "<", ">", "~", " ", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Backspace",
  "Delete", "Enter", "Tab", "Escape", "Home", "End", "PageUp", "PageDown", "F1", "F2", "F12", "F20", "F21", "f5",
  "Shift", "Meta", "Control", "Alt", "Dead", "Unidentified", "é", "ø", "ß", "Process", "CapsLock", "Insert",
];
const EVENT_CODES = [
  "KeyA", "KeyK", "KeyZ", "Digit0", "Digit1", "Digit9", "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash",
  "Semicolon", "Quote", "Comma", "Period", "Slash", "Backquote", "Space", "ArrowUp", "Enter", "Tab", "Escape",
  "ShiftLeft", "MetaLeft", "F1", "Numpad1", "KeyAA", "Key1", "digit1", "", "IntlBackslash", "Insert",
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const s = await importReference<Shortcuts>("apps/desktop/src/shared/shortcuts.ts");
  const commands = (s.SHORTCUT_COMMANDS as { id: string; fixed?: boolean }[]).filter((c) => !ZOOM.has(c.id));
  const ids = commands.map((c) => c.id);
  const changeable = commands.filter((c) => !c.fixed).map((c) => c.id);
  const cases: GoldenCase[] = [];

  const strip = <T>(record: Record<string, T>): Record<string, T> =>
    Object.fromEntries(Object.entries(record).filter(([id]) => !ZOOM.has(id)));
  const stripOverrides = (value: unknown): unknown => {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return strip(value as Record<string, unknown>);
    }
    return value;
  };

  const add = (
    label: string,
    overrides: unknown,
    probes: string[] = [],
    assignments: { id: string; shortcut: string; slot: number }[] = [],
    events: Record<string, unknown>[] = [],
  ) => {
    overrides = stripOverrides(overrides);
    // The zoom defaults hold keys in the reference's table that are free in the port's.
    const zoomKeys = new Set(["Cmd+-", "Cmd+0", "Cmd+Plus"]);
    assignments = assignments.map((assignment) =>
      zoomKeys.has(s.normalizeShortcut(assignment.shortcut) ?? "") ? { ...assignment, shortcut: "Cmd+Y" } : assignment,
    );
    const resolved = s.resolveShortcuts(overrides);
    const bindings = strip(resolved.bindings as Record<string, string[]>);
    const refusalOf = (shortcut: string) => {
      const refusal = s.getShortcutRefusal(shortcut);
      return refusal ? { reason: refusal.reason, command: refusal.command ?? null } : null;
    };
    cases.push({
      name: `${cases.length}: ${label}`,
      input: { overrides, probes, assignments, events },
      output: {
        bindings,
        commandByShortcut: [...resolved.commandByShortcut.entries()].filter(([, id]: [string, string]) => !ZOOM.has(id)),
        sanitized: strip(s.sanitizeShortcutOverrides(overrides)),
        probes: probes.map((shortcut) => ({
          shortcut,
          normalized: s.normalizeShortcut(shortcut),
          refusal: refusalOf(shortcut),
          macOS: s.isShortcutUsedByMacOSByDefault(shortcut),
          textEditing: s.isTextEditingShortcut(shortcut),
          withoutShift: s.withoutShift(shortcut),
          menuAccelerator: s.toMenuAccelerator(shortcut) ?? null,
        })),
        assignments: assignments.map(({ id, shortcut, slot }) => {
          const check = s.checkShortcutAssignment(resolved.bindings, id, shortcut);
          const assigned = s.assignShortcut(resolved.bindings, id, slot, shortcut);
          const removed = s.removeShortcut(resolved.bindings, id, slot);
          const reset = s.resetShortcut(resolved.bindings, id);
          return {
            id,
            shortcut,
            slot,
            status: check.status,
            refusal: check.refusal ? { reason: check.refusal.reason, command: check.refusal.command ?? null } : null,
            command: check.command ?? null,
            customized: s.isShortcutCustomized(resolved.bindings, id),
            assigned: strip(s.toShortcutOverrides(assigned)),
            removed: strip(s.toShortcutOverrides(removed)),
            reset: strip(s.toShortcutOverrides(reset.bindings)),
            takenFrom: reset.takenFrom.filter((id: string) => !ZOOM.has(id)),
            menuShortcut: s.getMenuShortcut(resolved.bindings[id]) ?? null,
          };
        }),
        events: events.map((event) => s.shortcutFromKeyboardEvent(event)),
      },
    });
  };

  const randomEvents = (count: number) =>
    Array.from({ length: count }, () => ({
      key: rng.pick(EVENT_KEYS),
      code: rng.pick(EVENT_CODES),
      metaKey: rng.chance(0.3),
      ctrlKey: rng.chance(0.2),
      altKey: rng.chance(0.25),
      shiftKey: rng.chance(0.3),
    }));
  const randomProbes = (count: number) => Array.from({ length: count }, () => rng.pick(KEY_FORMS));

  // Hand-picked.
  add("nothing saved", {}, KEY_FORMS);
  add("not an object", "Cmd+K", ["Cmd+K"]);
  add("null", null);
  add("array", [["Cmd+K"]]);
  add("one command moved", { newTab: ["Cmd+Y"] }, ["Cmd+Y"], [{ id: "newTab", shortcut: "Cmd+Y", slot: 0 }]);
  add("a key two commands claim", { newTab: ["Cmd+N"], newWindow: ["Cmd+T"] });
  add("a key a default holds is taken", { goBack: ["Cmd+R"] });
  add("a third key is dropped", { newTab: ["Cmd+Y", "Cmd+U", "Cmd+I"] });
  add("fixed commands are not changed", { copy: ["Cmd+Y"], undo: [], quit: ["Cmd+Shift+Y"] });
  add("a fixed key is refused", { newTab: ["Cmd+C", "Cmd+Y"] });
  add("a command keeps a default that could not be given", { quickLookSelection: ["Space"], openHelp: ["?"] });
  add("a key that could not be given to another", { newTab: ["Space", "?"] });
  add("empty arrays clear a command", { newTab: [], goBack: [] });
  add("unusable keys", { newTab: ["A", "Up", "Cmd+Tab", "Cmd+.", "nonsense", 5, null] });
  add("unknown commands", { launchMissiles: ["Cmd+Y"], newTab: ["Cmd+Y"], constructor: ["Cmd+U"] });
  add("an alternate is kept", { goBack: ["Cmd+["], goForward: [] });
  add("the same key twice", { newTab: ["Cmd+Y", "Cmd+Y"], newWindow: ["cmd+y"] });
  add(
    "a default taken by another and given back",
    { goBack: ["Cmd+Right"], goForward: ["Cmd+Left", "Cmd+]"] },
    [],
    [
      { id: "goBack", shortcut: "Cmd+Right", slot: 1 },
      { id: "goForward", shortcut: "Cmd+[", slot: 0 },
    ],
  );
  add("assignments", {}, [], [
    { id: "newTab", shortcut: "Cmd+T", slot: 0 },
    { id: "newTab", shortcut: "Cmd+N", slot: 0 },
    { id: "newTab", shortcut: "Cmd+Y", slot: 1 },
    { id: "newTab", shortcut: "Cmd+Y", slot: 5 },
    { id: "newTab", shortcut: "A", slot: 0 },
    { id: "newTab", shortcut: "Cmd+C", slot: 0 },
    { id: "newTab", shortcut: "Cmd+.", slot: 0 },
    { id: "newTab", shortcut: "Cmd+Tab", slot: 0 },
    { id: "newTab", shortcut: "Up", slot: 0 },
    { id: "newTab", shortcut: "Ctrl+Up", slot: 0 },
    { id: "quickLookSelection", shortcut: "Space", slot: 0 },
    { id: "goBack", shortcut: "Cmd+Right", slot: 0 },
    { id: "goBack", shortcut: "Cmd+Left", slot: 2 },
    { id: "openHelp", shortcut: "?", slot: 0 },
    { id: "pageUp", shortcut: "Ctrl+U", slot: 0 },
  ]);

  const poolKey = () => rng.pick(KEY_FORMS);
  while (cases.length < 300) {
    const overrides: Record<string, unknown> = {};
    const commandCount = rng.pick([0, 1, 2, 3, 5, 8, 15, 30]);
    for (let i = 0; i < commandCount; i += 1) {
      const id = rng.chance(0.08) ? rng.pick(["bogus", "constructor", "__proto__x", "ZOOM", ""]) : rng.chance(0.1) ? rng.pick(ids) : rng.pick(changeable);
      if (rng.chance(0.07)) {
        overrides[id] = rng.pick(JUNK);
        continue;
      }
      overrides[id] = Array.from({ length: rng.pick([0, 1, 1, 2, 2, 3, 4]) }, () =>
        rng.chance(0.05) ? rng.pick(JUNK) : poolKey(),
      );
    }
    const value: unknown = rng.chance(0.04) ? rng.pick(JUNK) : overrides;
    const assignments = Array.from({ length: rng.int(0, 4) }, () => ({
      id: rng.pick(ids),
      shortcut: poolKey(),
      slot: rng.pick([0, 0, 1, 1, 2, -1]),
    }));
    add(`random ${cases.length}`, value, randomProbes(rng.int(0, 8)), assignments, randomEvents(rng.int(0, 5)));
  }
  return cases;
}
