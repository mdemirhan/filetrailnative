// fitName (packages/core/src/fs/copyPasteNames.ts): a name with a suffix, within 255 UTF-8 bytes.
// Input: { baseName, suffix, extension }. Output: the name.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type NamesModule = { fitName: (baseName: string, suffix: string, extension: string) => string };

export const seed = 0xf17a0002;

const ZWJ_FAMILY = "👩‍👩‍👧‍👦";
const UNITS = [
  "a", "é", "é", "日", "😀", ZWJ_FAMILY, "🇹🇷", "👍🏽", "x ", " ", " ", "　", "ab c", "ñ", "ǆ",
  "각", "각", "\r\n", "ạ̈", "🏳️‍🌈",
];
const SUFFIXES = [" copy", " copy 2", " copy 10", " copy 99999", " copy 100000", " 2", ""];
const EXTENSIONS = ["", ".txt", ".tar.gz", ".app", ".jpeg", ".é", ".日本", "."];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const { fitName } = await importReference<NamesModule>("packages/core/src/fs/copyPasteNames.ts");
  const cases: GoldenCase[] = [];
  const seen = new Set<string>();
  const add = (baseName: string, suffix: string, extension: string) => {
    const key = JSON.stringify([baseName, suffix, extension]);
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    cases.push({
      name: `${cases.length}: ${Buffer.byteLength(baseName)} bytes`,
      input: { baseName, suffix, extension },
      output: fitName(baseName, suffix, extension),
    });
  };

  // Hand-picked.
  add("report", " copy", ".txt");
  add("", " copy", "");
  add("", " copy", ".txt");
  add("a".repeat(255), " copy", "");
  add("a".repeat(250), " copy", "");
  add("a".repeat(249), " copy", "");
  add("a".repeat(250), " copy", ".txt");
  add("a".repeat(246), " copy", ".txt");
  add("a".repeat(245), " copy", ".txt");
  add("a".repeat(100), " copy", ".x".repeat(80));
  add("a".repeat(100), " copy", `.${"x".repeat(250)}`);
  add("a".repeat(100), " copy", `.${"x".repeat(249)}`);
  add("a".repeat(100), " copy", `.${"é".repeat(125)}`);
  add("a".repeat(300), " copy", `.${"x".repeat(254)}`);
  add("é".repeat(200), " copy", ".txt");
  add("é".repeat(90), " copy", ".txt");
  add("👩‍👩‍👧‍👦".repeat(12), " copy", ".txt");
  add("日本語".repeat(28), " copy", ".txt");
  add(`${"a".repeat(240)}   b`, " copy", "");
  add(`${"a".repeat(244)}   b`, " copy", "");
  add(`${"a".repeat(240)}　　${"b".repeat(20)}`, " copy", "");
  add("a ".repeat(130), " copy", ".txt");
  add(" ".repeat(300), " copy", "");
  add(" ".repeat(200), " copy", "");
  for (let fill = 220; fill <= 250; fill += 1) {
    add("a".repeat(fill) + ZWJ_FAMILY, " copy", ".txt");
    add("a".repeat(fill) + "é́", " copy 2", "");
  }

  // Random, with lengths around the limit.
  while (cases.length < 320) {
    const target = rng.int(180, 300);
    let base = "";
    while (Buffer.byteLength(base) < target) {
      base += rng.pick(UNITS);
    }
    add(base, rng.pick(SUFFIXES), rng.pick(EXTENSIONS));
  }
  return cases;
}
