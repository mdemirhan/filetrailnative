// The golden file format and the driver gen.sh runs:
//   bun tools/parity/lib/golden.ts --out <dir> <suite...>
// writes <dir>/<suite>.json for each suite from tools/parity/golden/<suite>.ts.

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { Prng } from "./prng";
import { referenceCommit } from "./reference";

export type GoldenCase = { name: string; input: unknown; output: unknown };

// What tools/parity/golden/<suite>.ts exports.
export type GoldenGenerator = {
  seed: number;
  generate: (rng: Prng) => Promise<GoldenCase[]> | GoldenCase[];
};

export async function buildGolden(suite: string): Promise<string> {
  const generator = (await import(`../golden/${suite}.ts`)) as GoldenGenerator;
  if (typeof generator.seed !== "number" || typeof generator.generate !== "function") {
    throw new Error(`tools/parity/golden/${suite}.ts must export seed and generate`);
  }
  const cases = await generator.generate(new Prng(generator.seed));
  const names = new Set<string>();
  for (const testCase of cases) {
    if (names.has(testCase.name)) {
      throw new Error(`${suite}: duplicate case name "${testCase.name}"`);
    }
    names.add(testCase.name);
  }
  // Keys in a fixed order; each case as name, input, output.
  const golden = {
    suite,
    referenceCommit: referenceCommit(),
    seed: generator.seed,
    generator: `tools/parity/golden/${suite}.ts`,
    cases: cases.map(({ name, input, output }) => ({ name, input, output })),
  };
  return `${JSON.stringify(golden, null, 2)}\n`;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const outIndex = args.indexOf("--out");
  if (outIndex < 0 || args[outIndex + 1] === undefined) {
    console.error("usage: bun tools/parity/lib/golden.ts --out <dir> <suite...>");
    process.exit(2);
  }
  const out = args[outIndex + 1] as string;
  const suites = args.filter((_, index) => index !== outIndex && index !== outIndex + 1);
  mkdirSync(out, { recursive: true });
  for (const suite of suites) {
    writeFileSync(join(out, `${suite}.json`), await buildGolden(suite));
  }
}
