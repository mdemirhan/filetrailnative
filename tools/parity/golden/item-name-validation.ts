// getItemNameError and isMacOSPackageName (packages/contracts/src/itemName.ts).
// Input: the name. Output: { error?, package }.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type ItemNameModule = {
  getItemNameError: (name: string) => string | null;
  isMacOSPackageName: (name: string) => boolean;
};

export const seed = 0x17e30003;

const EDGE_CASES = [
  "", " ", "   ", "\t", "\n", ".", "..", "...", " . ", " .. ", "\u00a0.\u00a0", "\ufeff..\ufeff", ". .", "a", "report.pdf", ".env",
  "a:b", "C:\\notes.txt", "a/b", "/", "a/", "/a", "../escape", "sub/child", "nul\0byte", "\0", " \0 ", "a\0",
  "\u2028x\u2029", "\u0085x\u0085", "\u180ex\u180e", "\u200bx\u200b", "\u2003x\u2003", "\u202fx", "\u205fx", "\u1680x",
  "\ufeffx", "\u000bx\u000c", " é ", "Safari.app", "Foo.FRAMEWORK", "Sound.prefPane", "Applications", ".app", "a.app",
  "a.app ", " a.app", "x.xcodeproj", "x.Playground", "x.appex", "x.kext", "x.xpc", "x.plugin", "x.bundle", "x.APPEX",
  "x.app.bak", "x.apps", "app", "x.", "x..app", "a".repeat(254), "a".repeat(255), "a".repeat(256), ` ${"a".repeat(255)} `,
  `\u00a0${"a".repeat(255)}\u00a0`, "é".repeat(127), "é".repeat(128), "日".repeat(85), "日".repeat(86), "日".repeat(85) + "a",
  "😀".repeat(63), "😀".repeat(64), "😀".repeat(63) + "abc", "😀".repeat(63) + "abcd", "e\u0301".repeat(85), "e\u0301".repeat(86),
  "a/".repeat(3), "a\\b", "\\", "a\nb", "tab\tin", "end.", ".hidden", "-", "~", "`", "Ünï.APP",
];

const PIECES = [
  "a", "b", ".", "..", " ", "\u00a0", "é", "日", "😀", "/", "\0", ":", "\\", ".app", ".APP", ".framework", "x y",
  "\t", "\u2003", "\ufeff", "e\u0301",
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const mod = await importReference<ItemNameModule>("packages/contracts/src/itemName.ts");
  const cases: GoldenCase[] = [];
  const seen = new Set<string>();
  const add = (name: string) => {
    if (seen.has(name)) {
      return;
    }
    seen.add(name);
    const error = mod.getItemNameError(name);
    cases.push({
      name: `${cases.length}: ${JSON.stringify(name.slice(0, 30))}`,
      input: name,
      output: { ...(error === null ? {} : { error }), package: mod.isMacOSPackageName(name) },
    });
  };
  EDGE_CASES.forEach(add);
  while (cases.length < 320) {
    let name = "";
    const count = rng.int(0, 7);
    for (let index = 0; index < count; index++) {
      name += rng.pick(PIECES);
    }
    if (rng.chance(0.1)) {
      name = rng.pick(["a", "é", "日", "😀"]).repeat(rng.int(50, 130)) + name;
    }
    add(name);
  }
  return cases;
}
