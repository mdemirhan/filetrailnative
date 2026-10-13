// Turns what an engine recorded (absolute temp paths, random hidden names and journal ids,
// file ids, dates) into what two runs of any engine share, so outcomes compare as JSON.
// FTTestSupport.ExecNormalize does exactly the same in Swift; exec/selftest.sh checks that.
//
// The rules, applied in one walk (arrays in order, object keys sorted by UTF-16 code unit, so
// ordinals are numbered the same way on both sides):
// - keys `startedAt` and `finishedAt` are dropped;
// - `mtimeMs`: a number becomes "set";
// - `dev` and `ino`: a number becomes "dev-<n>" / "ino-<n>", numbered by first appearance;
// - `id`: a 16-hex-digit journal id becomes "journal-<n>";
// - `conflictId`: its trailing question counter "-<k>" becomes "-q<n>";
// - `analysisId` and `operationId` become "analysis" and "operation";
// - every string: each place (root, Trash) is replaced by its token wherever it occurs, longest
//   place first; a hidden staging name's 8 random hex digits become "~<n>";
// - afterwards, tree snapshots (`before`, `after`, `trash`, and the same under `recovery`) are
//   sorted by path again.
// It is idempotent: a normalized outcome comes out unchanged.

export type Place = { path: string; token: string };

const DROPPED_KEYS = new Set(["startedAt", "finishedAt"]);
const SNAPSHOT_KEYS = ["before", "after", "trash"];
const HIDDEN_NAME = /\.filetrail-([0-9a-f]{8})(?![0-9a-f])/g;
const JOURNAL_ID = /^[0-9a-f]{16}$/;
const QUESTION_COUNTER = /-(\d+)$/;

class Ordinals {
  private readonly seen = new Map<string, number>();

  of(key: string): number {
    let number = this.seen.get(key);
    if (number === undefined) {
      number = this.seen.size + 1;
      this.seen.set(key, number);
    }
    return number;
  }
}

// JavaScript's default string order (UTF-16 code units), which Swift reproduces.
export function compareUtf16(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

// Each place also under its /var spelling when it is under /private/var, longest first.
function expandPlaces(places: Place[]): Place[] {
  const all: Place[] = [];
  for (const place of places) {
    all.push(place);
    if (place.path.startsWith("/private/")) {
      all.push({ path: place.path.slice("/private".length), token: place.token });
    }
  }
  return all.sort((a, b) => b.path.length - a.path.length || compareUtf16(a.path, b.path));
}

export function normalizeOutcome(value: unknown, places: Place[]): unknown {
  const ordered = expandPlaces(places);
  const ordinals = {
    hidden: new Ordinals(),
    journal: new Ordinals(),
    question: new Ordinals(),
    dev: new Ordinals(),
    ino: new Ordinals(),
  };

  const text = (input: string): string => {
    let out = input;
    for (const place of ordered) {
      if (place.path.length > 0 && out.includes(place.path)) {
        out = out.split(place.path).join(place.token);
      }
    }
    return out.replace(HIDDEN_NAME, (_, hex: string) => `.filetrail-~${ordinals.hidden.of(hex)}`);
  };

  const member = (key: string, item: unknown): unknown => {
    if (key === "mtimeMs" && typeof item === "number") {
      return "set";
    }
    if ((key === "dev" || key === "ino") && typeof item === "number") {
      return `${key}-${ordinals[key].of(String(item))}`;
    }
    if (key === "id" && typeof item === "string" && JOURNAL_ID.test(item)) {
      return `journal-${ordinals.journal.of(item)}`;
    }
    if (key === "conflictId" && typeof item === "string") {
      const counted = text(item);
      const match = QUESTION_COUNTER.exec(counted);
      return match ? `${counted.slice(0, match.index)}-q${ordinals.question.of(match[1] as string)}` : counted;
    }
    if (key === "analysisId" && typeof item === "string") {
      return "analysis";
    }
    if (key === "operationId" && typeof item === "string") {
      return "operation";
    }
    return walk(item);
  };

  const walk = (item: unknown): unknown => {
    if (typeof item === "string") {
      return text(item);
    }
    if (Array.isArray(item)) {
      return item.map(walk);
    }
    if (item !== null && typeof item === "object") {
      const out: Record<string, unknown> = {};
      for (const key of Object.keys(item).sort(compareUtf16)) {
        if (DROPPED_KEYS.has(key)) {
          continue;
        }
        const child = (item as Record<string, unknown>)[key];
        if (child !== undefined) {
          out[key] = member(key, child);
        }
      }
      return out;
    }
    return item;
  };

  const normalized = walk(value);
  sortSnapshots(normalized);
  if (normalized !== null && typeof normalized === "object" && "recovery" in normalized) {
    sortSnapshots((normalized as Record<string, unknown>).recovery);
  }
  return normalized;
}

function sortSnapshots(outcome: unknown): void {
  if (outcome === null || typeof outcome !== "object") {
    return;
  }
  const record = outcome as Record<string, unknown>;
  for (const key of SNAPSHOT_KEYS) {
    const list = record[key];
    if (Array.isArray(list)) {
      list.sort((a, b) => compareUtf16(String(a?.path), String(b?.path)));
    }
  }
}

// Usage: bun tools/parity/exec/normalize.ts <raw.json>   (raw: what `run.ts --raw` prints;
// prints the normalized outcome)
if (import.meta.main) {
  const [file] = process.argv.slice(2);
  if (file === undefined) {
    console.error("usage: bun tools/parity/exec/normalize.ts <raw.json>");
    process.exit(2);
  }
  const raw = JSON.parse(await Bun.file(file).text()) as { places: Place[]; outcome: unknown };
  process.stdout.write(`${JSON.stringify(normalizeOutcome(raw.outcome, raw.places), null, 2)}\n`);
}
