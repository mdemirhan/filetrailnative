// withoutNestedPaths (packages/contracts/src/paths.ts): which picked paths are kept.
// Input: the picked paths. Output: the paths kept, in order.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type PathsModule = { withoutNestedPaths: (paths: readonly string[]) => string[] };

export const seed = 0x9a7a5001;

const EDGE_CASES: Array<[string, string[]]> = [
  ["empty", []],
  ["root alone", ["/"]],
  ["root takes everything", ["/", "/a", "/a/b", "relative"]],
  ["root picked last", ["/a/b", "/x", "/"]],
  ["child before parent", ["/a/b", "/a"]],
  ["parent before child", ["/a", "/a/b", "/c"]],
  ["deep descendant", ["/a/b/c/d", "/a/b"]],
  ["exact duplicates", ["/a", "/a", "/b", "/a"]],
  ["sibling with shared prefix", ["/ab", "/a", "/a b", "/a-b"]],
  ["trailing slash is not an ancestor", ["/a/", "/a/b"]],
  ["trailing slash and a double slash", ["/a/", "/a//b"]],
  ["double slash under root", ["/", "//x"]],
  ["double slash root kept apart", ["//", "/a"]],
  ["case differs", ["/A", "/a/b", "/Users/Me", "/users/me/x"]],
  ["nfc parent, nfd child", ["/Café", "/Café/x"]],
  ["nfd parent, nfc child", ["/Café", "/Café/x"]],
  ["nfc parent, nfc child", ["/Café", "/Café/x"]],
  ["nfc and nfd duplicates", ["/Zoë", "/Zoë", "/Zoë"]],
  ["combining mark after a slash", ["/a", "/a/́"]],
  ["relative paths", ["a", "a/b", "b/c", "b"]],
  ["empty string picked", ["", "/a", "a"]],
  ["dot components", ["/a/.", "/a/./b", "/a/..", "/a/../c"]],
  ["volumes and trashes", ["/Volumes/X", "/Volumes/X/.Trashes", "/Volumes/Xy/.Trashes"]],
  ["emoji", ["/🎉", "/🎉/👩‍👩‍👧‍👦", "/🎈/🎉"]],
  ["spaces", ["/a b", "/a b/c", "/a  b/c"]],
  ["home and trash", ["/Users/me", "/Users/me/.Trash/x", "/Users/meme"]],
];

const COMPONENTS = [
  "a", "b", "A", "ab", "é", "é", "É", "x y", ".", "..", "", "́", "🎉", "ß", "SS",
  "Users", "Volumes", ".Trash", "Ω", "Ω",
];

function randomPath(rng: Prng): string {
  if (rng.chance(0.03)) {
    return "/";
  }
  const parts = rng.pickMany(COMPONENTS, rng.int(1, 4));
  let path = (rng.chance(0.88) ? "/" : "") + parts.join("/");
  if (rng.chance(0.08)) {
    path += "/";
  }
  return path;
}

function randomPaths(rng: Prng): string[] {
  const roots = Array.from({ length: rng.int(1, 3) }, () => randomPath(rng));
  const paths: string[] = [];
  const count = rng.int(1, 9);
  for (let index = 0; index < count; index++) {
    const roll = rng.next();
    if (roll < 0.3) {
      paths.push(rng.pick(roots));
    } else if (roll < 0.7) {
      const tail = rng.pickMany(COMPONENTS, rng.int(1, 3)).join("/");
      paths.push(`${rng.pick(roots).replace(/\/$/u, "")}/${tail}`);
    } else if (roll < 0.85 && paths.length > 0) {
      paths.push(rng.pick(paths));
    } else {
      paths.push(randomPath(rng));
    }
  }
  return paths;
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const { withoutNestedPaths } = await importReference<PathsModule>("packages/contracts/src/paths.ts");
  const cases: GoldenCase[] = EDGE_CASES.map(([name, paths]) => ({
    name,
    input: paths,
    output: withoutNestedPaths(paths),
  }));
  for (let index = 0; index < 320; index++) {
    const paths = randomPaths(rng);
    cases.push({ name: `random ${index}`, input: paths, output: withoutNestedPaths(paths) });
  }
  return cases;
}
