// Runs a reference module under the reference app's own Electron (as plain Node, ELECTRON_RUN_AS_NODE),
// for answers that depend on the runtime's ICU data: Intl date formats differ between Bun's and
// Chromium's. The module is bundled to JavaScript with Bun first; calls go in as JSON, answers come out.

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { referenceRoot } from "./reference";

export type ReferenceCall = { fn: string; args: unknown[] };

function electronBinary(): string {
  const root = referenceRoot();
  const packageDir = join(root, "apps/desktop/node_modules/electron");
  const relative = readFileSync(join(packageDir, "path.txt"), "utf8").trim();
  return join(packageDir, "dist", relative);
}

const RUNNER = `
import { readFileSync } from "node:fs";
const module = await import("./module.mjs");
const { calls } =JSON.parse(readFileSync(0, "utf8"));
const resolved = Intl.DateTimeFormat().resolvedOptions();
const answers = calls.map((call) => module[call.fn](...call.args));
process.stdout.write(JSON.stringify({ locale: resolved.locale, timeZone: resolved.timeZone, answers }));
`;

// Calls `module[fn](...args)` for each call, in one Electron process with the time zone `timeZone`.
export async function runInElectron(
  modulePath: string,
  calls: ReferenceCall[],
  timeZone: string,
): Promise<{ locale: string; timeZone: string; answers: unknown[] }> {
  const directory = mkdtempSync(join(tmpdir(), "filetrail-parity-"));
  try {
    const built = await Bun.build({ entrypoints: [join(referenceRoot(), modulePath)], target: "node", format: "esm" });
    if (!built.success || built.outputs.length !== 1) {
      throw new Error(`could not bundle ${modulePath}: ${built.logs.join("; ")}`);
    }
    writeFileSync(join(directory, "module.mjs"), await (built.outputs[0] as Blob).text());
    writeFileSync(join(directory, "run.mjs"), RUNNER);
    const child = Bun.spawn([electronBinary(), join(directory, "run.mjs")], {
      env: { ...process.env, ELECTRON_RUN_AS_NODE: "1", TZ: timeZone, LC_ALL: "en_US.UTF-8", LANG: "en_US.UTF-8" },
      stdin: new Blob([JSON.stringify({ calls })]),
      stdout: "pipe",
      stderr: "pipe",
    });
    const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    if (code !== 0) {
      throw new Error(`electron exited with ${code}: ${err.slice(0, 500)}`);
    }
    return JSON.parse(out);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
