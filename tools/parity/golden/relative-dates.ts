// Dates for lists and tooltips (apps/desktop/src/renderer/lib/formatting.ts) in the fixed time zone
// America/Los_Angeles and the locale en-US, which the Swift test sets the same way.
// The reference's answers are computed by Electron running as Node (the original app's own runtime),
// so the ICU data is Chromium's.
// Input: { now, ms, timeZone } (epoch milliseconds). Output: { relative, exact, short, withinLastHour }.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { type ReferenceCall, runInElectron } from "../lib/electron";

export const seed = 0x4e1a0003;

export const TIME_ZONE = "America/Los_Angeles";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

// Local (Los Angeles) wall times: ordinary days, the days around both daylight saving changes,
// and the turn of the year. Built after TZ is set.
function nowCandidates(): number[] {
  return [
    new Date(2026, 9, 1, 14, 45).getTime(),
    new Date(2026, 9, 13, 14, 38, 20, 500).getTime(),
    new Date(2026, 2, 9, 1, 30).getTime(),
    new Date(2026, 2, 8, 3, 30).getTime(),
    new Date(2026, 10, 2, 10, 0).getTime(),
    new Date(2026, 0, 2, 0, 5).getTime(),
    new Date(2026, 11, 31, 23, 59).getTime(),
  ];
}

const OFFSETS_MS = [
  -2 * HOUR, -MINUTE - 1, -MINUTE, -MINUTE + 1, 0, 1, 20_000, 59_999, MINUTE - 1, MINUTE, MINUTE + 1,
  2 * MINUTE, 59 * MINUTE + 59_000, HOUR - 1, HOUR, HOUR + 1, 3 * HOUR, 23 * HOUR + 59 * MINUTE,
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  // The local calendar arithmetic below is done in the fixed zone.
  const previousZone = process.env.TZ;
  process.env.TZ = TIME_ZONE;
  try {
    const pairs: Array<[number, number]> = [];
    const seen = new Set<string>();
    const add = (now: number, ms: number) => {
      const key = `${now}/${ms}`;
      if (!seen.has(key)) {
        seen.add(key);
        pairs.push([now, ms]);
      }
    };

    const nows = nowCandidates();
    for (const now of nows) {
      for (const offset of OFFSETS_MS) {
        add(now, now - offset);
      }
      // The edges of each of the last ten calendar days, as the local clock counts them.
      const today = new Date(now);
      for (let daysAgo = 0; daysAgo <= 9; daysAgo++) {
        const start = new Date(today.getFullYear(), today.getMonth(), today.getDate() - daysAgo).getTime();
        add(now, start - 1);
        add(now, start);
        add(now, start + 12 * HOUR);
      }
      // The year edges.
      add(now, new Date(today.getFullYear(), 0, 1).getTime() - 1);
      add(now, new Date(today.getFullYear(), 0, 1).getTime());
    }
    while (pairs.length < 500) {
      const now = rng.pick(nows);
      // Ages from seconds to years, spread evenly over the powers of ten; some in the future.
      const age = Math.floor(10 ** (3 + rng.next() * 8.6));
      add(now, rng.chance(0.08) ? now + age : now - age);
    }

    const calls: ReferenceCall[] = pairs.flatMap(([now, ms]) => [
      { fn: "formatRelativeDateTime", args: [ms, now] },
      { fn: "formatExactDateTime", args: [ms] },
      { fn: "formatShortDateTime", args: [ms] },
      { fn: "isWithinLastHour", args: [ms, now] },
    ]);
    const result = await runInElectron("apps/desktop/src/renderer/lib/formatting.ts", calls, TIME_ZONE);
    if (result.timeZone !== TIME_ZONE || result.locale !== "en-US") {
      throw new Error(`relative-dates needs ${TIME_ZONE} and en-US, got ${result.timeZone} ${result.locale}`);
    }
    return pairs.map(([now, ms], index) => ({
      name: `${new Date(now).toISOString()} vs ${new Date(ms).toISOString()}`,
      input: { now, ms, timeZone: TIME_ZONE },
      output: {
        relative: result.answers[index * 4],
        exact: result.answers[index * 4 + 1],
        short: result.answers[index * 4 + 2],
        withinLastHour: result.answers[index * 4 + 3],
      },
    }));
  } finally {
    if (previousZone === undefined) {
      delete process.env.TZ;
    } else {
      process.env.TZ = previousZone;
    }
  }
}
