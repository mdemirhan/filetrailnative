// The List view's column math (apps/desktop/src/renderer/lib/detailsLayout.ts): which columns show, the table's width,
// fitting the columns into a narrow pane, and the width a double-click on a divider gives a column.
// Input: { op: "visible", visibility, order } | { op: "tableWidth", columns, widths } |
//   { op: "fit", columns, widths, availableWidth } |
//   { op: "fitWidth", key, headerWidth, valueWidths, valueExtraWidth }.
// Output: the columns, the width, { columns, widths } or the fitted width.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type Widths = Record<string, number>;

type LayoutModule = {
  DETAILS_LAYOUT: Record<string, number>;
  getVisibleDetailColumns: (visibility: Record<string, boolean>, order: string[]) => string[];
  getDetailsTableWidth: (widths: Widths, columns: string[]) => number;
  fitDetailColumns: (args: { columns: string[]; widths: Widths; availableWidth: number }) => {
    columns: string[];
    widths: Widths;
  };
  getDetailColumnFitWidth: (
    key: string,
    args: { headerWidth: number; valueWidths: number[]; valueExtraWidth: number },
  ) => number;
};

type PreferencesModule = {
  DEFAULT_DETAIL_COLUMN_WIDTHS: Widths;
  DETAIL_COLUMN_WIDTH_LIMITS: Record<string, { min: number; max: number }>;
  OPTIONAL_DETAIL_COLUMN_KEYS: string[];
};

export const seed = 0xde7a115;

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const layout = await importReference<LayoutModule>("apps/desktop/src/renderer/lib/detailsLayout.ts");
  const preferences = await importReference<PreferencesModule>("apps/desktop/src/shared/appPreferences.ts");
  const limits = preferences.DETAIL_COLUMN_WIDTH_LIMITS;
  const optional = preferences.OPTIONAL_DETAIL_COLUMN_KEYS;
  const keys = ["name", ...optional];
  const cases: GoldenCase[] = [];

  // The constants the stylesheet and the code keep, so a change to either shows.
  cases.push({ name: "constants", input: { op: "constants" }, output: layout.DETAILS_LAYOUT });

  // Which columns show.
  const visibilities: Array<Record<string, boolean>> = [
    { modified: true, size: true, kind: true, created: false, permissions: false },
    { modified: false, size: true, kind: true, created: false, permissions: true },
    { modified: true, size: true, kind: true, created: true, permissions: true },
    { modified: false, size: false, kind: false, created: false, permissions: false },
  ];
  const orders: string[][] = [
    [...optional],
    ["kind", "permissions", "modified", "created", "size"],
    ["permissions", "created", "kind", "size", "modified"],
  ];
  for (const visibility of visibilities) {
    for (const order of orders) {
      cases.push({
        name: `visible ${cases.length}`,
        input: { op: "visible", visibility, order },
        output: layout.getVisibleDetailColumns(visibility, order),
      });
    }
  }

  const defaults = preferences.DEFAULT_DETAIL_COLUMN_WIDTHS;
  const full = ["name", "modified", "size", "kind"];
  // The widths a pane gives: hand-picked around the boundaries of the original's tests, then random.
  const fullWidth = 728 + 36 + 24;
  for (const availableWidth of [
    0, -5, 1, 96, 120, 240, 264, 400, 467, 468, 469, 500, fullWidth - 161, fullWidth - 160, fullWidth - 100,
    fullWidth - 1, fullWidth, fullWidth + 1, 2000,
  ]) {
    cases.push({
      name: `fit default ${availableWidth}`,
      input: { op: "fit", columns: full, widths: defaults, availableWidth },
      output: layout.fitDetailColumns({ columns: full, widths: defaults, availableWidth }),
    });
  }

  const randomWidths = (): Widths => {
    const widths: Widths = { folder: rng.int(80, 720) };
    for (const key of keys) {
      const range = limits[key] ?? { min: 80, max: 720 };
      widths[key] = rng.int(range.min, range.max);
    }
    return widths;
  };
  const randomColumns = (): string[] => {
    const chosen = optional.filter(() => rng.chance(0.6));
    // Search results add Folder, anywhere among the optional columns.
    if (rng.chance(0.3)) {
      chosen.splice(rng.int(0, chosen.length), 0, "folder");
    }
    return ["name", ...chosen];
  };

  for (let index = 0; index < 400; index += 1) {
    const columns = randomColumns();
    const widths = randomWidths();
    const table = layout.getDetailsTableWidth(widths, columns);
    // Around the table's own width, well under it, and sometimes unmeasured or absurdly small.
    const availableWidth = rng.pick([
      () => table + rng.int(-3, 3),
      () => rng.int(1, table + 100),
      () => rng.int(0, 200),
      () => 0,
      () => table - rng.int(1, 400),
    ])();
    cases.push({
      name: `fit random ${index}`,
      input: { op: "fit", columns, widths, availableWidth },
      output: layout.fitDetailColumns({ columns, widths, availableWidth }),
    });
    if (index % 4 === 0) {
      cases.push({
        name: `tableWidth random ${index}`,
        input: { op: "tableWidth", columns, widths },
        output: layout.getDetailsTableWidth(widths, columns),
      });
    }
  }

  // Fitting one column to its title and widest value.
  for (const key of optional.concat("name")) {
    for (let index = 0; index < 12; index += 1) {
      const headerWidth = Math.round(rng.next() * 12000) / 100;
      const valueWidths = Array.from({ length: rng.int(0, 6) }, () => Math.round(rng.next() * 40000) / 100);
      const valueExtraWidth = key === "name" ? 26 : 0;
      cases.push({
        name: `fitWidth ${key} ${index}`,
        input: { op: "fitWidth", key, headerWidth, valueWidths, valueExtraWidth },
        output: layout.getDetailColumnFitWidth(key, { headerWidth, valueWidths, valueExtraWidth }),
      });
    }
  }
  // The original's own cases.
  const fitCases: Array<[string, number, number[], number]> = [
    ["kind", 28, [60.2, 84.5], 0],
    ["size", 69.4, [24], 0],
    ["name", 40, [300], 24],
    ["permissions", 69.4, [36.5], 0],
    ["permissions", 69.4, [24], 0],
    ["size", 26, [], 0],
    ["name", 40, [5000], 24],
  ];
  for (const [key, headerWidth, valueWidths, valueExtraWidth] of fitCases) {
    cases.push({
      name: `fitWidth original ${cases.length}`,
      input: { op: "fitWidth", key, headerWidth, valueWidths, valueExtraWidth },
      output: layout.getDetailColumnFitWidth(key, { headerWidth, valueWidths, valueExtraWidth }),
    });
  }
  return cases;
}
