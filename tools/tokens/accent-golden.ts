// Records the reference's accent math (renderer/lib/accent.ts and theme.ts) for the nine preset
// accents, black, white and 300 seeded random colours, in light and dark, into
// Tests/Golden/accent.json.
//   bun tools/tokens/accent-golden.ts
// Self-contained on purpose: it will be moved under tools/parity/ later.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  REFERENCE_COMMIT,
  REPO_ROOT,
  RENDERER,
  evalColorMix,
  referenceFile,
  writeGolden,
} from "./lib";

// The reference files as they are at the pinned commit, copied to build/ so they can be
// imported without touching (or depending on the state of) the reference checkout.
const stage = join(REPO_ROOT, "build/tokens-ref/renderer/lib");
mkdirSync(stage, { recursive: true });
for (const file of ["accent.ts", "theme.ts", "colorUtils.ts"]) {
  writeFileSync(join(stage, file), referenceFile(`${RENDERER}/lib/${file}`));
}

// theme.ts writes to document.documentElement; a recording stub captures what it sets.
const recorded: Record<string, string> = {};
(globalThis as Record<string, unknown>).document = {
  documentElement: {
    dataset: {},
    style: {
      setProperty(name: string, value: string) {
        recorded[name] = value;
      },
    },
  },
};

const accent = await import(join(stage, "accent.ts"));
const theme = await import(join(stage, "theme.ts"));

const PRESETS = [
  "#007aff",
  "#a550a7",
  "#f74f9e",
  "#e0383e",
  "#f7821b",
  "#ffc600",
  "#62ba46",
  "#8c8c8c",
  "#d4845a",
];
const EXTREMES = ["#000000", "#ffffff"];

function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const random = mulberry32(0xf11e7a11);
const randomColors: string[] = [];
for (let i = 0; i < 300; i += 1) {
  const bytes = [0, 1, 2].map(() => Math.floor(random() * 256));
  randomColors.push(`#${bytes.map((b) => b.toString(16).padStart(2, "0")).join("")}`);
}

type Case = { input: { accent: string; theme: "light" | "dark" }; output: unknown };
const cases: Case[] = [];

for (const hex of [...PRESETS, ...EXTREMES, ...randomColors]) {
  for (const mode of ["light", "dark"] as const) {
    for (const key of Object.keys(recorded)) delete recorded[key];
    theme.applyAppearance({ theme: mode, accent: hex });
    const tokens = accent.generateAccentTokens(hex, mode);
    // The Rename sheet's marks are plain CSS in styles.css (color-mix on the accent), so they
    // are evaluated here rather than by accent.ts.
    const markText =
      mode === "dark" ? evalColorMix(`color-mix(in srgb, ${hex} 65%, white)`) : tokens.pathCrumbHover;
    const markBg =
      mode === "dark" ? evalColorMix(`color-mix(in srgb, ${hex} 16%, transparent)`) : tokens.softBg;
    cases.push({
      input: { accent: hex, theme: mode },
      output: {
        tokens,
        cssVariables: { ...recorded },
        batchRenameMarkText: markText,
        batchRenameMarkBg: markBg,
      },
    });
  }
}

writeGolden("accent.json", {
  source: { commit: REFERENCE_COMMIT, files: ["accent.ts", "theme.ts", "colorUtils.ts"] },
  cases,
});
