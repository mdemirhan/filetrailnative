// Writes Resources/Acknowledgements/{index.json, <id>.txt}: the open-source software the native bundle ships and each
// license text, which the Acknowledgements window lists. Port of apps/desktop/scripts/thirdPartyLicenses.ts for what
// applies to the native app (no Electron, Chromium, React, Zod or node-gyp-build): fd and its licenses in
// Resources/fd/licenses. A component whose license can not be found fails the generator, as it fails the original's
// build.
// Usage: bun tools/acknowledgements/gen.ts [--check]   (--check changes nothing and fails when the files are stale)
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dir, "../..");
const outDir = join(root, "Resources/Acknowledgements");
const check = process.argv.includes("--check");

type Component = {
  id: string;
  name: string;
  license: string;
  url: string;
  version: string;
  // License files, in the order their texts are joined.
  files: string[];
};

type IndexEntry = { id: string; name: string; version: string | null; license: string; url: string; file: string };

const fdDir = join(root, "Resources/fd");
const fdManifest = JSON.parse(readFileSync(join(fdDir, "manifest.json"), "utf8")) as { version?: string };
if (typeof fdManifest.version !== "string" || fdManifest.version.length === 0) {
  throw new Error("Resources/fd/manifest.json has no version.");
}

const components: Component[] = [
  {
    id: "fd",
    name: "fd",
    license: "MIT or Apache 2.0",
    url: "https://github.com/sharkdp/fd",
    version: fdManifest.version,
    files: [join(fdDir, "licenses", "LICENSE-MIT"), join(fdDir, "licenses", "LICENSE-APACHE")],
  },
];

const wanted = new Map<string, string>();
const index: IndexEntry[] = components.map(({ id, name, license, url, version, files }) => {
  if (files.length === 0) {
    throw new Error(`No license file listed for ${name}.`);
  }
  const text = files
    .map((file) => {
      if (!existsSync(file)) {
        throw new Error(`No license file for ${name}: ${file} is missing.`);
      }
      return readFileSync(file, "utf8").trim();
    })
    .join(`\n\n${"-".repeat(72)}\n\n`);
  const fileName = `${id}.txt`;
  wanted.set(fileName, `${text}\n`);
  return { id, name, version, license, url, file: fileName };
});
wanted.set("index.json", `${JSON.stringify(index, null, 2)}\n`);

if (check) {
  const problems: string[] = [];
  for (const [name, contents] of wanted) {
    const path = join(outDir, name);
    if (!existsSync(path)) problems.push(`${name} is missing`);
    else if (readFileSync(path, "utf8") !== contents) problems.push(`${name} is out of date`);
  }
  for (const name of existsSync(outDir) ? readdirSync(outDir) : []) {
    if (!wanted.has(name)) problems.push(`${name} should not be there`);
  }
  if (problems.length > 0) {
    console.error(`Resources/Acknowledgements is stale (${problems.join("; ")}): run tools/acknowledgements/gen.sh`);
    process.exit(1);
  }
  console.log(`acknowledgements up to date (${index.length} component(s))`);
} else {
  mkdirSync(outDir, { recursive: true });
  for (const name of readdirSync(outDir)) {
    if (!wanted.has(name)) rmSync(join(outDir, name), { force: true });
  }
  for (const [name, contents] of wanted) writeFileSync(join(outDir, name), contents);
  console.log(`wrote Resources/Acknowledgements (${index.length} component(s))`);
}
