// addNumberToName (apps/desktop/src/shared/batchRename.ts): "name 2.ext", shortened to fit 255 bytes.
// Input: { name, isFolder, separator, number }. Output: { name, keptStemLength, stemLength }.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type BatchRenameModule = {
  addNumberToName: (
    name: string,
    isFolder: boolean,
    separator: string,
    number: number,
  ) => { name: string; keptStemLength: number; stemLength: number };
};

export const seed = 0x40a30005;

const ZWJ_FAMILY = "👩‍👩‍👧‍👦";
const NAMES = [
  "Lisbon.jpg", "Lisbon", ".env", "a.", "a.b.c", "archive.tar.gz", "x copy.txt", "Tool.app", "日本語.txt", "Café.txt",
  "Café.txt", "name with spaces .txt", "trailing  ", "..", "...", "a..b", ".", "", "x.é",
];
const SEPARATORS = [" ", "-", "_", " - ", "", " ", " (", "é"];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const { addNumberToName } = await importReference<BatchRenameModule>(
    "apps/desktop/src/shared/batchRename.ts",
  );
  const cases: GoldenCase[] = [];
  const seen = new Set<string>();
  const add = (name: string, isFolder: boolean, separator: string, number: number) => {
    const key = JSON.stringify([name, isFolder, separator, number]);
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    cases.push({
      name: `${cases.length}: ${JSON.stringify(name.slice(0, 30))}`,
      input: { name, isFolder, separator, number },
      output: addNumberToName(name, isFolder, separator, number),
    });
  };
  for (const name of NAMES) {
    for (const isFolder of [false, true]) {
      add(name, isFolder, " ", 2);
      add(name, isFolder, "-", 100_000);
    }
  }
  add("a".repeat(255), false, " ", 2);
  add(`${"a".repeat(250)}.txt`, false, " ", 2);
  add(`${"a".repeat(240)}.${"x".repeat(14)}`, false, " ", 10);
  add(`a.${"x".repeat(252)}`, false, " ", 2);
  add(`a.${"x".repeat(253)}`, false, " ", 2);
  add(`${"a".repeat(252)}.txt`, false, " ", 123_456);
  add(`${ZWJ_FAMILY.repeat(12)}.txt`, false, " ", 2);
  add(`${"é".repeat(90)}.txt`, false, " ", 2);
  add(`${"a".repeat(240)}   b.txt`, false, " ", 2);
  while (cases.length < 220) {
    const unit = rng.pick(["a", "é", "é", "日", "😀", ZWJ_FAMILY, " ", "x y"]);
    const stem = unit.repeat(rng.int(1, Math.ceil(300 / Buffer.byteLength(unit))));
    const extension = rng.pick(["", ".txt", ".tar.gz", ".jpeg", ".日本"]);
    add(
      stem + extension,
      rng.chance(0.2),
      rng.pick(SEPARATORS),
      rng.pick([2, 3, 9, 10, 99, 1000, 99_999, 100_000]),
    );
  }
  return cases;
}
