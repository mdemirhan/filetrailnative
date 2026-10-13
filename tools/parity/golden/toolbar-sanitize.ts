// sanitizeTopToolbarItems, the palette, and the edits of the order (apps/desktop/src/shared/toolbarItems.ts).
// Input: { value, ops }; the value is any JSON. Output: { sanitized, palette, edited }: the sanitized order, what the
// palette still offers for it, and the order after the ops (add, insert, move, remove) are applied one by one.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Op =
  | { op: "add"; item: string }
  | { op: "insert"; item: string; index: number }
  | { op: "move"; from: number; to: number }
  | { op: "remove"; index: number };

type ToolbarModule = {
  TOOLBAR_ITEM_IDS: string[];
  DEFAULT_TOP_TOOLBAR_ITEMS: string[];
  sanitizeTopToolbarItems: (value: unknown) => string[];
  getTopToolbarPaletteItems: (items: string[]) => string[];
  addTopToolbarItem: (items: string[], item: string) => string[];
  insertTopToolbarItem: (items: string[], item: string, index: number) => string[];
  moveTopToolbarItem: (items: string[], from: number, to: number) => string[];
  removeTopToolbarItem: (items: string[], index: number) => string[];
  isRequiredTopToolbarItem: (id: string) => boolean;
};

export const seed = 0x70c1ba12;

const JUNK: unknown[] = [
  null, 0, 1, -1, 1.5, "", "back", "launchMissiles", true, false, {}, { back: true }, [], [null], [[]], ["back"],
  "title", ["title"], [1, 2, 3], [{ id: "back" }], "topSeparator", ["BACK"], ["back "], [" back"],
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const m = await importReference<ToolbarModule>("apps/desktop/src/shared/toolbarItems.ts");
  const ids = m.TOOLBAR_ITEM_IDS;
  const cases: GoldenCase[] = [];
  const add = (label: string, value: unknown, ops: Op[] = []) => {
    const sanitized = m.sanitizeTopToolbarItems(value);
    let edited = sanitized;
    for (const op of ops) {
      if (op.op === "add") edited = m.addTopToolbarItem(edited, op.item);
      else if (op.op === "insert") edited = m.insertTopToolbarItem(edited, op.item, op.index);
      else if (op.op === "move") edited = m.moveTopToolbarItem(edited, op.from, op.to);
      else edited = m.removeTopToolbarItem(edited, op.index);
    }
    cases.push({
      name: `${cases.length}: ${label}`,
      input: { value, ops },
      output: { sanitized, palette: m.getTopToolbarPaletteItems(sanitized), edited },
    });
  };

  // Hand-picked.
  add("default", m.DEFAULT_TOP_TOOLBAR_ITEMS);
  add("empty list", []);
  add("not a list", "back");
  add("null", null);
  add("object", { back: true });
  add("only separators", ["topSeparator", "topSeparator", "topSeparator"]);
  add("repeated items", ["back", "back", "forward", "back", "title", "title"]);
  add("required items first", ["title", "clipboard", "search", "viewOptions"]);
  add("unknown items", ["nope", "back", "BACK", "back "]);
  add("every item", ids);
  add("every item twice", [...ids, ...ids]);
  add("separator in the middle", ["back", "topSeparator", "forward", "topSeparator", "up"]);
  add("ops on the default", m.DEFAULT_TOP_TOOLBAR_ITEMS, [
    { op: "add", item: "up" },
    { op: "insert", item: "topSeparator", index: 2 },
    { op: "move", from: 0, to: 5 },
    { op: "remove", index: 1 },
    { op: "remove", index: 3 },
    { op: "insert", item: "settings", index: -4 },
    { op: "insert", item: "help", index: 400 },
    { op: "move", from: 99, to: 0 },
    { op: "remove", index: 99 },
    { op: "remove", index: -1 },
  ]);

  const randomOps = (length: number): Op[] =>
    Array.from({ length: rng.int(0, 6) }, () => {
      const roll = rng.int(0, 3);
      const span = length + 3;
      if (roll === 0) return { op: "add", item: rng.pick(ids) };
      if (roll === 1) return { op: "insert", item: rng.pick(ids), index: rng.int(-2, span) };
      if (roll === 2) return { op: "move", from: rng.int(-1, span), to: rng.int(-1, span) };
      return { op: "remove", index: rng.int(-1, span) };
    });

  while (cases.length < 200) {
    const roll = rng.next();
    let value: unknown;
    if (roll < 0.1) {
      value = rng.pick(JUNK);
    } else {
      const length = rng.int(0, 45);
      value = Array.from({ length }, () => {
        const pick = rng.next();
        if (pick < 0.7) return rng.pick(ids);
        if (pick < 0.8) return "topSeparator";
        return rng.pick(JUNK);
      });
    }
    const length = Array.isArray(value) ? value.length : 0;
    add(`random ${cases.length}`, value, rng.chance(0.6) ? randomOps(length) : []);
  }
  return cases;
}
