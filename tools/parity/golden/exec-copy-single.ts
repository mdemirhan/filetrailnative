// The reference copy engine copying one file into an empty folder (tools/parity/exec/run.ts).
// Input: the scenario. Output: the tree before and after, the result, questions and statuses.

import { type Scenario, runScenario } from "../exec/run";
import type { GoldenCase } from "../lib/golden";

export const seed = 0;

const SCENARIO: Scenario = {
  name: "copy one file into an empty folder",
  tree: [
    { path: "source/notes.txt", kind: "file", content: "File Trail parity\n", mode: "0644" },
    { path: "destination", kind: "dir", mode: "0755" },
  ],
  paste: { mode: "copy", sources: ["source/notes.txt"], destination: "destination" },
  policy: { file: "skip", directory: "skip", mismatch: "skip" },
  answers: [],
  stopAt: null,
};

export async function generate(): Promise<GoldenCase[]> {
  return [{ name: SCENARIO.name, input: SCENARIO, output: await runScenario(SCENARIO) }];
}
