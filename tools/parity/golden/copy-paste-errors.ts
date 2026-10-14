// describeCopyPasteError (packages/core/src/fs/copyPasteErrors.ts) and the native addon's error text
// (native_errno_error and native_errno_code in packages/native-fs/src/native_errors.c).
// Native input: { kind: "native", errno, syscall, path, dest|null }. Output: { code, message, described }.
//   Every errno from 0 to one past ELAST, each named as native_errors.c names it ("UNKNOWN" otherwise),
//   with libc's strerror, as the addon builds it; checked against the addon's own errors first.
// Node-shaped input: { kind: "error", message, code: string|number|null } or { kind: "string", value }.
//   Output: { described }.

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { dlopen, FFIType } from "bun:ffi";

import type { GoldenCase } from "../lib/golden";
import type { Prng } from "../lib/prng";
import { importReference, referenceRoot } from "../lib/reference";

type ErrorsModule = { describeCopyPasteError: (error: unknown) => string };

type NativeAddon = {
  nativeCopyFile: (src: string, dst: string, stopFlag?: Int32Array) => Promise<void>;
  nativeRenameExclusive: (from: string, to: string) => Promise<void>;
  nativeGetFlags: (path: string) => Promise<number>;
  nativeIsCaseSensitive: (path: string) => Promise<boolean | null>;
};

export const seed = 0xe7707001;

const libc = dlopen("/usr/lib/libSystem.B.dylib", {
  strerror: { args: [FFIType.i32], returns: FFIType.cstring },
});

function strerror(errnum: number): string {
  return String(libc.symbols.strerror(errnum));
}

// The errno numbers by name, from the SDK's sys/errno.h; and ELAST.
function errnoNumbers(): { numbers: Map<string, number>; last: number } {
  const sdk = spawnSync("xcrun", ["--show-sdk-path"], { encoding: "utf8" }).stdout.trim();
  const header = readFileSync(join(sdk, "usr/include/sys/errno.h"), "utf8");
  const numbers = new Map<string, number>();
  for (const match of header.matchAll(/^#define\s+(E[A-Z0-9]+)\s+(\d+)\b/gmu)) {
    numbers.set(match[1] as string, Number(match[2]));
  }
  const last = numbers.get("ELAST");
  if (last === undefined) {
    throw new Error("no ELAST in sys/errno.h");
  }
  numbers.delete("ELAST");
  return { numbers, last };
}

// native_errno_code's names, in its order, from the reference's own source.
function nativeNames(): string[] {
  const source = readFileSync(join(referenceRoot(), "packages/native-fs/src/native_errors.c"), "utf8");
  return [...source.matchAll(/ERRNO_NAME\((E[A-Z0-9]+)\)/gu)].map((match) => match[1] as string);
}

function nativeError(code: string, errnum: number, syscall: string, path: string, dest: string | null) {
  const description = strerror(errnum);
  const message =
    dest === null
      ? `${code}: ${description}, ${syscall} '${path}'`
      : `${code}: ${description}, ${syscall} '${path}' -> '${dest}'`;
  return Object.assign(new Error(message), {
    code,
    errno: errnum,
    syscall,
    path,
    ...(dest === null ? {} : { dest }),
  });
}

// The addon's own errors, which the text built here must match.
async function checkAgainstAddon(nameOf: (errnum: number) => string): Promise<void> {
  const require = createRequire(import.meta.url);
  const addon = require(join(referenceRoot(), "packages/native-fs/build/Release/native-fs.node")) as NativeAddon;
  const root = mkdtempSync(join(tmpdir(), "golden-copy-errors-"));
  try {
    writeFileSync(join(root, "a.txt"), "a");
    writeFileSync(join(root, "b.txt"), "b");
    const calls: Array<[() => Promise<unknown>, number, string, string, string | null]> = [
      [() => addon.nativeCopyFile(join(root, "a.txt"), join(root, "b.txt")), 17, "copyfile", join(root, "a.txt"), join(root, "b.txt")],
      [
        () => addon.nativeCopyFile(join(root, "a.txt"), join(root, "b.txt", "c")),
        20,
        "copyfile",
        join(root, "a.txt"),
        join(root, "b.txt", "c"),
      ],
      [
        () => addon.nativeCopyFile(join(root, "a.txt"), join(root, "b.txt"), new Int32Array([1])),
        89,
        "copyfile",
        join(root, "a.txt"),
        join(root, "b.txt"),
      ],
      [() => addon.nativeRenameExclusive(join(root, "a.txt"), join(root, "b.txt")), 17, "rename", join(root, "a.txt"), join(root, "b.txt")],
      [() => addon.nativeGetFlags(join(root, "gone")), 2, "lstat", join(root, "gone"), null],
      [() => addon.nativeIsCaseSensitive(join(root, "gone")), 2, "pathconf", join(root, "gone"), null],
    ];
    for (const [call, errnum, syscall, path, dest] of calls) {
      const actual = (await call().then(
        () => null,
        (error: unknown) => error,
      )) as (Error & Record<string, unknown>) | null;
      const expected = nativeError(nameOf(errnum), errnum, syscall, path, dest);
      const same =
        actual !== null &&
        actual.message === expected.message &&
        actual.code === expected.code &&
        actual.errno === expected.errno &&
        actual.syscall === expected.syscall &&
        actual.path === expected.path &&
        actual.dest === (dest ?? undefined);
      if (!same) {
        throw new Error(`the addon's error differs: ${actual?.message} vs ${expected.message}`);
      }
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const PLACES: Array<[string, string, string | null]> = [
  ["copyfile", "/Volumes/Disk/a.txt", "/Users/me/Documents/a.txt"],
  ["lstat", "/Users/me/café \u{1F600}.txt", null],
  ["rename", "/tmp/x 'quoted'", "/tmp/y\nz"],
];

const NODE_CODES = [
  "ERR_FS_EISDIR",
  "ENOTRASH",
  "ABORT_ERR",
  "EWHATEVER",
  "UNKNOWN",
  "enoent",
  "",
];

export async function generate(rng: Prng): Promise<GoldenCase[]> {
  const { describeCopyPasteError } = await importReference<ErrorsModule>("packages/core/src/fs/copyPasteErrors.ts");
  const { numbers, last } = errnoNumbers();
  const names = nativeNames();
  const nameByNumber = new Map<number, string>();
  for (const name of names) {
    const number = numbers.get(name);
    if (number === undefined) {
      throw new Error(`${name} is not in sys/errno.h`);
    }
    if (!nameByNumber.has(number)) {
      nameByNumber.set(number, name);
    }
  }
  const nameOf = (errnum: number) => nameByNumber.get(errnum) ?? "UNKNOWN";
  await checkAgainstAddon(nameOf);

  const cases: GoldenCase[] = [];
  for (let errnum = 0; errnum <= last + 1; errnum++) {
    const [syscall, path, dest] = PLACES[errnum % PLACES.length] as [string, string, string | null];
    const error = nativeError(nameOf(errnum), errnum, syscall, path, dest);
    cases.push({
      name: `native errno ${errnum} ${nameOf(errnum)}`,
      input: { kind: "native", errno: errnum, syscall, path, dest },
      output: { code: error.code, message: error.message, described: describeCopyPasteError(error) },
    });
  }

  const addError = (name: string, message: string, code: string | number | null) => {
    const error = code === null ? new Error(message) : Object.assign(new Error(message), { code });
    cases.push({ name, input: { kind: "error", message, code }, output: { described: describeCopyPasteError(error) } });
  };
  for (const name of names) {
    addError(`node error ${name}`, `${name}: something, open '/x/y'`, name);
  }
  for (const code of NODE_CODES) {
    addError(`node error code "${code}"`, `failed with ${code || "nothing"}`, code);
  }
  // Node's fs.rm says "Path is a directory: rm returned EISDIR (is a directory) /var/…".
  addError("node rm of a folder", "Path is a directory: rm returned EISDIR (is a directory) /var/x", "ERR_FS_EISDIR");
  addError("codeless error", "Something else", null);
  addError("codeless empty message", "", null);
  addError("numeric code", "The operation was aborted", 20);
  addError("numeric errno-like code", "EIO: i/o error", -5);
  for (let index = 0; index < 20; index++) {
    const code = rng.pick([...names, ...NODE_CODES]);
    addError(`random ${index}`, `random ${rng.int(0, 1_000_000)} '/p/${index}'`, rng.chance(0.2) ? null : code);
  }
  for (const value of ["plain", "", "ENOENT"]) {
    cases.push({ name: `thrown string "${value}"`, input: { kind: "string", value }, output: { described: describeCopyPasteError(value) } });
  }
  return cases;
}
