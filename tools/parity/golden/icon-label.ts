// shortenNameInMiddle (apps/desktop/src/renderer/lib/iconLabel.ts) with a fake text width that both
// sides compute the same way: each code point is 2 + (code point mod 5) wide, and a text fits when
// its width is at most `limit`.
// Input: { name, extension, limit }. Output: the shortened name.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type IconLabelModule = {
  shortenNameInMiddle: (name: string, extension: string, fits: (text: string) => boolean) => string;
};

export const seed = 0x1c0b0005;

function fakeWidth(text: string): number {
  let width = 0;
  for (const character of text) {
    width += 2 + ((character.codePointAt(0) ?? 0) % 5);
  }
  return width;
}

const WORDS = [
  "Panorama", "Miradouro", "Monte", "report", "Final", "IMG", "2026", "scan", "draft", "notes", "a", "b",
  "Résumé", "naïve", "日本語", "🎉", "👩‍👩‍👧‍👦", "𝔘𝔫𝔦", "x y", "  ", "Ünï", "é", "-", "_", ".", "(1)", "copy",
];
const EXTENSIONS = ["", "txt", "jpeg", "tar.gz", "md", "PDF", "j", "swift", "numbers", "app", "é", "🎉"];

function randomName(rng: Prng): { name: string; extension: string } {
  const stem = rng.pickMany(WORDS, rng.int(1, 9)).join(rng.chance(0.5) ? " " : rng.pick(["", "-", "_"]));
  const extension = rng.pick(EXTENSIONS);
  const roll = rng.next();
  if (roll < 0.75) {
    return { name: extension ? `${stem}.${extension}` : stem, extension };
  }
  if (roll < 0.85) {
    // An extension that is not on the name.
    return { name: stem, extension: extension || "txt" };
  }
  if (roll < 0.92) {
    // An extension that differs by case.
    return { name: extension ? `${stem}.${extension.toUpperCase()}` : stem, extension };
  }
  // A name that is only the extension.
  return { name: `.${extension || "txt"}`, extension: extension || "txt" };
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const { shortenNameInMiddle } = await importReference<IconLabelModule>("apps/desktop/src/renderer/lib/iconLabel.ts");
  const cases: GoldenCase[] = [];
  const seen = new Set<string>();
  const add = (name: string, extension: string, limit: number) => {
    const key = JSON.stringify([name, extension, limit]);
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    cases.push({
      name: `${cases.length}: ${name} | ${extension} | ${limit}`,
      input: { name, extension, limit },
      output: shortenNameInMiddle(name, extension, (text) => fakeWidth(text) <= limit),
    });
  };

  const edge: Array<[string, string]> = [
    ["", ""],
    ["a", ""],
    ["a.txt", "txt"],
    [".txt", "txt"],
    ["Miradouro do Monte.jpeg", "jpeg"],
    ["Panorama Miradouro do Monte.jpeg", "jpeg"],
    ["no extension at all in this long name", ""],
    ["🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉.png", "png"],
    ["éééééééé.txt", "txt"],
    ["trailing space before the cut here and there.txt", "txt"],
    ["name with a NO-BREAK   space and   em spaces  .md", "md"],
    ["UPPER.TXT", "txt"],
    ["archive.tar.gz", "gz"],
    ["archive.tar.gz", "tar.gz"],
  ];
  for (const [name, extension] of edge) {
    const total = fakeWidth(name);
    for (const limit of [0, 1, 6, 12, Math.floor(total / 3), Math.floor(total / 2), total - 1, total, total + 1]) {
      add(name, extension, Math.max(0, limit));
    }
  }
  while (cases.length < 300) {
    const { name, extension } = randomName(rng);
    const total = fakeWidth(name);
    add(name, extension, rng.chance(0.1) ? rng.int(0, 12) : rng.int(Math.floor(total * 0.15), total + 4));
  }
  return cases;
}
