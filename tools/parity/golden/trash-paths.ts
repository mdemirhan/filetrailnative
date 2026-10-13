// isInsideTrash and isTrashFolder (packages/contracts/src/trash.ts).
// Input: { path, homePath }. Output: { insideTrash, trashFolder }.

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference } from "../lib/reference";

type TrashModule = {
  isInsideTrash: (path: string, homePath: string) => boolean;
  isTrashFolder: (path: string, homePath: string) => boolean;
};

export const seed = 0x7a5a0002;

const HOME = "/Users/me";

const EDGE_CASES: Array<[string, string, string]> = [
  ["home trash", "/Users/me/.Trash", HOME],
  ["home trash, trailing slash", "/Users/me/.Trash/", HOME],
  ["home trash, many trailing slashes", "/Users/me/.Trash///", HOME],
  ["inside home trash", "/Users/me/.Trash/a.txt", HOME],
  ["deep inside home trash", "/Users/me/.Trash/a/b/c", HOME],
  ["home trash, upper case", "/USERS/ME/.TRASH", HOME],
  ["home trash, home in upper case", "/Users/me/.Trash", "/USERS/ME"],
  ["home with trailing slash", "/Users/me/.Trash", "/Users/me/"],
  ["home with many trailing slashes", "/Users/me/.Trash/x", "/Users/me///"],
  ["not the trash: .Trash2", "/Users/me/.Trash2", HOME],
  ["not the trash: Trash", "/Users/me/Trash", HOME],
  ["not the trash: home itself", "/Users/me", HOME],
  ["not the trash: other user", "/Users/you/.Trash", HOME],
  ["not the trash: prefix home", "/Users/meme/.Trash", HOME],
  ["empty home", "/.Trash", ""],
  ["root home", "/.Trash", "/"],
  ["root home, inside", "/.Trash/x", "/"],
  ["slashes-only home", "/.Trash", "///"],
  ["relative home", "me/.Trash", "me"],
  ["empty path", "", HOME],
  ["root path", "/", HOME],
  ["nfc home, nfd path", "/Users/José/.Trash", "/Users/José"],
  ["nfd home, nfc path", "/Users/José/.Trash/x", "/Users/José"],
  ["home with combining mark", "/Users/mé/.Trash", HOME],
  ["combining mark after trash slash", "/Users/me/.Trash/́x", HOME],
  ["combining mark on trash name", "/Users/me/.Trash́", HOME],
  ["greek final sigma home", "/Users/ΑΣ/.Trash", "/Users/ΑΣ"],
  ["greek sigma home, lower path", "/Users/ας/.Trash", "/Users/ΑΣ"],
  ["greek sigma home, medial path", "/Users/ασ/.Trash", "/Users/ΑΣ"],
  ["dotted capital I home", "/Users/i̇/.Trash", "/Users/İ"],
  ["sharp s home", "/Users/ß/.Trash", "/Users/ẞ"],
  ["kelvin sign home", "/Users/k/.Trash", "/Users/K"],
  ["ohm sign home", "/Users/ω/.Trash", "/Users/Ω"],
  ["angstrom sign home", "/Users/å/.Trash", "/Users/Å"],
  ["cherokee home", "/Users/ꭰ/.Trash", "/Users/Ꭰ"],
  ["georgian home", "/Users/ა/.Trash", "/Users/Ა"],
  ["volume trashes", "/Volumes/Data/.Trashes", HOME],
  ["volume trashes, trailing slash", "/Volumes/Data/.Trashes/", HOME],
  ["volume user trash", "/Volumes/Data/.Trashes/501", HOME],
  ["volume user trash, trailing slashes", "/Volumes/Data/.Trashes/501//", HOME],
  ["inside volume user trash", "/Volumes/Data/.Trashes/501/a.txt", HOME],
  ["volume trashes, upper case", "/VOLUMES/DATA/.TRASHES/501", HOME],
  ["volume with spaces", "/Volumes/My Disk/.Trashes", HOME],
  ["volume with empty name", "/Volumes//.Trashes", HOME],
  ["volume .Trashes2", "/Volumes/Data/.Trashes2", HOME],
  ["volume .Trash (not .Trashes)", "/Volumes/Data/.Trash", HOME],
  ["nested volume path", "/Volumes/Data/x/.Trashes", HOME],
  ["volumes itself", "/Volumes/.Trashes", HOME],
  ["relative volumes", "Volumes/Data/.Trashes", HOME],
  ["double slash after volumes", "/Volumes//Data/.Trashes", HOME],
  ["newline before trailing slash", "/Volumes/Data/.Trashes/501\n/", HOME],
  ["newline before trailing slashes", "/Volumes/Data/.Trashes/501\n//", HOME],
  ["newline as user trash", "/Volumes/Data/.Trashes/\n//", HOME],
  ["line separator before trailing slashes", "/Users/me/.Trash/ //", HOME],
  ["carriage return home trash", "/Users/me/.Trash\r/", HOME],
  ["emoji volume", "/Volumes/🎉/.Trashes/501", HOME],
  ["nfd volume name", "/Volumes/Café/.Trashes", HOME],
  ["home on a volume", "/Volumes/Data/Users/me/.Trash", "/Volumes/Data/Users/me"],
];

const HOMES = [
  HOME, "/Users/Me", "/users/ME/", "", "/", "/Users/José", "/Users/José", "/Users/ΑΣ",
  "/Users/İ", "/Users/ẞ", "/Volumes/Data/Users/me", "/Users/a b", "/Users/K",
];
const TRASH_NAMES = [".Trash", ".trash", ".TRASH", ".Trashes", ".Trash2", "Trash", ".Tras", ".Trash́"];
const VOLUME_NAMES = ["Data", "My Disk", "", "🎉", "Café", "Café", "ΑΣ", "x/y"];
const VOLUME_TRASHES = [".Trashes", ".TRASHES", ".trashes", ".Trashes2", ".Trash", "Trashes"];
const TAILS = ["", "501", "a.txt", "a/b", "́", "Σ", ".Trash", "\n", "x "];

function flipCase(rng: Prng, text: string): string {
  return Array.from(text, (char) => (rng.chance(0.3) ? char.toUpperCase() : char)).join("");
}

function flipNormalization(rng: Prng, text: string): string {
  const roll = rng.next();
  return roll < 0.2 ? text.normalize("NFD") : roll < 0.4 ? text.normalize("NFC") : text;
}

function withTail(rng: Prng, path: string): string {
  let result = path;
  const tailCount = rng.pick([0, 0, 1, 1, 2]);
  for (let index = 0; index < tailCount; index++) {
    result += `/${rng.pick(TAILS)}`;
  }
  return result + "/".repeat(rng.pick([0, 0, 0, 1, 2]));
}

function randomCase(rng: Prng): { path: string; homePath: string } {
  const homePath = rng.pick(HOMES);
  const roll = rng.next();
  let path: string;
  if (roll < 0.45) {
    const home = rng.chance(0.8) ? homePath.replace(/\/+$/u, "") : rng.pick(HOMES);
    path = `${home}/${rng.pick(TRASH_NAMES)}`;
  } else if (roll < 0.9) {
    path = `${rng.pick(["/Volumes", "/volumes", "/VOLUMES", "Volumes", "/Volume"])}/${rng.pick(VOLUME_NAMES)}/${rng.pick(VOLUME_TRASHES)}`;
  } else {
    path = rng.pick(["/", "", "/Users", "/Volumes", "/tmp/.Trash", "/Users/me/Documents"]);
  }
  return {
    path: flipNormalization(rng, flipCase(rng, withTail(rng, path))),
    homePath: flipNormalization(rng, rng.chance(0.2) ? flipCase(rng, homePath) : homePath),
  };
}

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const trash = await importReference<TrashModule>("packages/contracts/src/trash.ts");
  const run = (path: string, homePath: string) => ({
    input: { path, homePath },
    output: {
      insideTrash: trash.isInsideTrash(path, homePath),
      trashFolder: trash.isTrashFolder(path, homePath),
    },
  });
  const cases: GoldenCase[] = EDGE_CASES.map(([name, path, homePath]) => ({ name, ...run(path, homePath) }));
  for (let index = 0; index < 340; index++) {
    const { path, homePath } = randomCase(rng);
    cases.push({ name: `random ${index}`, ...run(path, homePath) });
  }
  return cases;
}
