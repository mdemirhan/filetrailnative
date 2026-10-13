// formatSize (apps/desktop/src/renderer/lib/formatting.ts): decimal units, one decimal under 9.95.
// Input: { bytes, status }. Output: the text.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type FormattingModule = {
  formatSize: (bytes: number | null, status: "ready" | "deferred" | "unavailable") => string;
};

export const seed = 0x51ce0004;

const EDGE_BYTES = [
  0, 1, 9, 999, 1000, 1001, 1049, 1050, 1051, 1249, 1250, 1251, 1950, 2250, 9949, 9950, 9951, 9959,
  9960, 9994, 9999, 10_000, 10_049, 10_050, 10_449, 10_450, 10_500, 12_500, 99_499, 99_500, 99_949,
  99_950, 99_999, 100_000, 999_499, 999_500, 999_699, 999_700, 999_949, 999_950, 999_999, 1_000_000,
  1_250_000, 9_950_000, 99_433_647_655, 226_587_120_929, 999_500_000, 999_950_000_000,
  999_999_999_999, 1_000_000_000_000, 999_500_000_000_000, 999_999_999_999_999, 1_000_000_000_000_000,
  2_500_000_000_000_000, 9_995_000_000_000_000 / 10, Number.MAX_SAFE_INTEGER,
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const { formatSize } = await importReference<FormattingModule>("apps/desktop/src/renderer/lib/formatting.ts");
  const cases: GoldenCase[] = [];
  const seen = new Set<string>();
  const add = (bytes: number | null, status: "ready" | "deferred" | "unavailable") => {
    const name = `${status} ${bytes}`;
    if (seen.has(name)) {
      return;
    }
    seen.add(name);
    cases.push({ name, input: { bytes, status }, output: formatSize(bytes, status) });
  };
  for (const bytes of EDGE_BYTES) {
    add(bytes, "ready");
  }
  for (const status of ["ready", "deferred", "unavailable"] as const) {
    add(null, status);
  }
  add(0, "deferred");
  add(1234, "deferred");
  add(5, "unavailable");
  add(123_456, "unavailable");
  while (cases.length < 300) {
    const roll = rng.next();
    const magnitude = Math.floor(10 ** (rng.next() * 15.9));
    if (roll < 0.5) {
      add(magnitude, "ready");
    } else if (roll < 0.75) {
      // Exact halves of a tenth of a unit, where rounding has to pick a side: 2.25 KB, 12.5 MB.
      const unit = 1000 ** rng.int(1, 5);
      const whole = rng.int(1, 99);
      const fraction = rng.pick([0.25, 0.75, 0.5, 0.05, 0.95]);
      add(Math.min(Math.floor((whole + fraction) * unit), Number.MAX_SAFE_INTEGER), "ready");
    } else if (roll < 0.9) {
      // Just under a step.
      const unit = 1000 ** rng.int(1, 5);
      add(Math.min(unit * 1000 - rng.int(1, 600) * (unit / 1000), Number.MAX_SAFE_INTEGER), "ready");
    } else if (roll < 0.95) {
      add(magnitude, "deferred");
    } else {
      add(magnitude, "unavailable");
    }
  }
  return cases;
}
