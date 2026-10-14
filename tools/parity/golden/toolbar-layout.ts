// The top toolbar's fitting and overflow (apps/desktop/src/renderer/lib/topToolbarLayout.ts).
// Input: { items, widths, shown, availableWidth, optionalCount, centers, pointerX }: a saved order (any ids, sanitized
// first), the measured width of each slot by key, which slots have something on screen, the room for the row, a count
// to select, and the drop centers. Output: { slots, capsules, visibleCount, selected, selectedForCount, dropIndex }.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { importReference, referenceRoot } from "../lib/reference";

type Slot = { id: string; key: string };
type Edges = { start: boolean; end: boolean };

type LayoutModule = {
  resolveTopToolbarSlots: (items: string[]) => Slot[];
  resolveToolbarCapsules: (slots: Slot[], isShown?: (slot: Slot) => boolean) => Map<string, Edges>;
  selectTopToolbarSlots: (slots: Slot[], optionalCount: number) => Slot[];
  resolveVisibleOptionalCount: (args: {
    slots: Slot[];
    widths: Map<string, number>;
    availableWidth: number;
  }) => number;
  resolveToolbarDropIndex: (centers: number[], pointerX: number) => number;
};

type TokensModule = {
  EXPLORER_LAYOUT: Record<string, number>;
  TREE_LAYOUT: Record<string, number>;
};

type ToolbarModule = {
  TOOLBAR_ITEM_IDS: string[];
  DEFAULT_TOP_TOOLBAR_ITEMS: string[];
  sanitizeTopToolbarItems: (value: unknown) => string[];
};

export const seed = 0x70b1a1;

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const layout = await importReference<LayoutModule>("apps/desktop/src/renderer/lib/topToolbarLayout.ts");
  const toolbar = await importReference<ToolbarModule>("apps/desktop/src/shared/toolbarItems.ts");
  const tokens = await importReference<TokensModule>("apps/desktop/src/renderer/lib/layoutTokens.ts");
  const constants = await importReference<{ TOP_TOOLBAR_LAYOUT: Record<string, number> }>(
    "apps/desktop/src/renderer/lib/topToolbarLayout.ts",
  );
  const ids = toolbar.TOOLBAR_ITEM_IDS;
  const cases: GoldenCase[] = [];

  // The sizes the stylesheet lays the toolbar and the tree out from, read as the original's own tests read them
  // (topToolbarLayout.test.ts, layoutTokens.test.ts), and the constants its code keeps.
  const styles = readFileSync(join(referenceRoot(), "apps/desktop/src/renderer/styles.css"), "utf8");
  const sizeOf = (property: string) => Number(new RegExp(`${property}: (\\d+)px;`, "u").exec(styles)?.[1]);
  const heightOf = (selector: string) =>
    Number(new RegExp(`${selector.replace(/[.]/g, "\\.")} \\{[^}]*?\\bheight: (\\d+)px`, "u").exec(styles)?.[1]);
  cases.push({
    name: "stylesheet",
    input: {},
    output: {
      stylesheet: {
        itemGap: sizeOf("--toolbar-item-gap"),
        edgedItemInset: sizeOf("--toolbar-edged-item-inset"),
        capsulePadding: sizeOf("--toolbar-capsule-padding"),
        titleMinWidth: sizeOf("--toolbar-title-min-width"),
        overflowButtonWidth: sizeOf("--toolbar-overflow-button-width"),
        searchWidth: sizeOf("--toolbar-search-width"),
        searchMinWidth: sizeOf("--toolbar-search-min-width"),
        controlHeight: sizeOf("--toolbar-control-height"),
        buttonWidth: sizeOf("--toolbar-button-width"),
        treeRowHeight: heightOf("\n.sidebar-main-native .tree-row"),
        compactTreeRowHeight: heightOf(".compact-tree-view .sidebar-main-native .tree-row"),
      },
      topToolbarLayout: constants.TOP_TOOLBAR_LAYOUT,
      explorerLayout: tokens.EXPLORER_LAYOUT,
      treeLayout: tokens.TREE_LAYOUT,
    },
  });

  const add = (
    label: string,
    rawItems: string[],
    widthOf: (slot: Slot) => number,
    hidden: Set<string>,
    availableWidth: number,
    optionalCount: number,
    centers: number[],
    pointerX: number,
  ) => {
    const items = toolbar.sanitizeTopToolbarItems(rawItems);
    const slots = layout.resolveTopToolbarSlots(items);
    const widths: Record<string, number> = {};
    for (const slot of slots) {
      if (slot.id === "title" || slot.id === "search") continue;
      widths[slot.key] = widthOf(slot);
    }
    const shown = slots.filter((slot) => !hidden.has(slot.key)).map((slot) => slot.key);
    const capsules = layout.resolveToolbarCapsules(slots, (slot) => shown.includes(slot.key));
    const visibleCount = layout.resolveVisibleOptionalCount({
      slots,
      widths: new Map(Object.entries(widths)),
      availableWidth,
    });
    cases.push({
      name: `${cases.length}: ${label}`,
      input: { items: rawItems, widths, shown, availableWidth, optionalCount, centers, pointerX },
      output: {
        slots: slots.map((slot) => slot.key),
        capsules: Object.fromEntries(capsules),
        visibleCount,
        selected: layout.selectTopToolbarSlots(slots, visibleCount).map((slot) => slot.key),
        selectedForCount: layout.selectTopToolbarSlots(slots, optionalCount).map((slot) => slot.key),
        dropIndex: layout.resolveToolbarDropIndex(centers, pointerX),
      },
    });
  };

  // A toolbar as drawn: 32 wide buttons, the view switch 122, the clipboard button wider, a separator 0.
  const drawn = (slot: Slot) =>
    slot.id === "view" ? 122 : slot.id === "clipboard" ? 52 : slot.id === "topSeparator" ? 0 : 32;
  const none = new Set<string>();

  // Hand-picked: the default toolbar at every width a window can have, and the edges of the fit.
  for (const width of [0, 1, 40, 200, 380, 412, 430, 462, 494, 500, 560, 600, 700, 892, 1200]) {
    add(`default at ${width}`, toolbar.DEFAULT_TOP_TOOLBAR_ITEMS, drawn, none, width, 3, [], 0);
  }
  add("default, clipboard empty", toolbar.DEFAULT_TOP_TOOLBAR_ITEMS, drawn, new Set(["clipboard"]), 892, 3, [], 0);
  add("not measured yet", toolbar.DEFAULT_TOP_TOOLBAR_ITEMS, () => 0, none, 892, 2, [], 0);
  add("only separators", ["topSeparator", "topSeparator", "back", "topSeparator"], drawn, none, 600, 1, [], 0);
  add("every item", ids, drawn, none, 1400, 10, [10, 40, 80], 50);
  add("every item, narrow", ids, drawn, none, 700, 20, [10, 40, 80], 5);
  add("separators around required items", [
    "topSeparator",
    "title",
    "topSeparator",
    "search",
    "topSeparator",
    "back",
    "topSeparator",
  ], drawn, none, 500, 1, [100, 200], 200);
  add("drop index ties", toolbar.DEFAULT_TOP_TOOLBAR_ITEMS, drawn, none, 892, 4, [20, 60, 60, 300], 60);

  while (cases.length < 220) {
    const length = rng.int(0, 24);
    const items = Array.from({ length }, () => (rng.chance(0.15) ? "topSeparator" : rng.pick(ids)));
    const widths = new Map<string, number>();
    const widthOf = (slot: Slot) => {
      const known = widths.get(slot.key);
      if (known !== undefined) return known;
      const roll = rng.next();
      const width = roll < 0.6 ? 32 : roll < 0.7 ? 122 : roll < 0.8 ? 0 : rng.int(1, 140);
      widths.set(slot.key, width);
      return width;
    };
    const slots = layout.resolveTopToolbarSlots(toolbar.sanitizeTopToolbarItems(items));
    const hidden = new Set(slots.filter(() => rng.chance(0.1)).map((slot) => slot.key));
    const centers = Array.from({ length: rng.int(0, 8) }, () => rng.int(0, 900)).sort((a, b) => a - b);
    add(
      `random ${cases.length}`,
      items,
      widthOf,
      hidden,
      rng.chance(0.1) ? 0 : rng.int(0, 1400),
      rng.int(-1, 30),
      centers,
      rng.int(-10, 950),
    );
  }
  return cases;
}
