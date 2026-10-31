// Deterministic fixture trees under $FILETRAIL_DEV_CACHE/fixtures (default ~/Library/Caches/filetrail-dev).
// Usage: bun tools/fixtures/generate.ts [lighthouse|bench|names ...]
// Each tree is rebuilt only when its version stamp is missing or differs.

import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  readdirSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  truncateSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { deflateSync } from "node:zlib";

const CACHE = process.env.FILETRAIL_DEV_CACHE ?? join(homedir(), "Library/Caches/filetrail-dev");
const ROOT = join(CACHE, "fixtures");

// The Swift and Electron captures freeze their clocks to this local time.
export const FIXTURE_NOW = new Date(2026, 9, 13, 14, 38, 0);
const MIN = 60_000;
const DAY = 24 * 60 * MIN;
const STAMP_NAME = ".fixture-version";
const VERSIONS = { lighthouse: "1", bench: "1", names: "1" } as const;

// ---- helpers ----------------------------------------------------------------

const minutesAgo = (m: number) => new Date(FIXTURE_NOW.getTime() - m * MIN);
// A local date and time in 2026 unless a year is given: at("Oct 1 14:46").
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
function at(text: string): Date {
  const m = /^(\w{3}) (\d+)(?: (\d{4}))? ?(\d+)?:?(\d+)?$/.exec(text);
  if (!m) throw new Error(`bad date ${text}`);
  return new Date(
    Number(m[3] ?? 2026),
    MONTHS.indexOf(m[1] as string),
    Number(m[2]),
    Number(m[4] ?? 14),
    Number(m[5] ?? 46),
  );
}

// Small deterministic random numbers.
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function textOfSize(label: string, size: number): Buffer {
  const out = Buffer.alloc(size, 0x20);
  const head = Buffer.from(`${label}\n`);
  head.copy(out, 0, 0, Math.min(head.length, size));
  if (size > 0) out[size - 1] = 0x0a;
  return out;
}

function write(path: string, content: Buffer | string, when?: Date): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
  if (when) utimesSync(path, when, when);
}

// A file of a given apparent size that takes (almost) no disk space.
function sparse(path: string, size: number, when?: Date): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, "");
  truncateSync(path, size);
  if (when) utimesSync(path, when, when);
}

function crc32(buf: Buffer): number {
  let c = ~0;
  for (const b of buf) {
    c ^= b;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}

// A gradient picture as a PNG, so Quick Look thumbnails differ between files.
function png(width: number, height: number, from: [number, number, number], to: [number, number, number]): Buffer {
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 3 + 1);
    for (let x = 0; x < width; x++) {
      const t = (x / width + y / height) / 2;
      for (let c = 0; c < 3; c++) {
        raw[row + 1 + x * 3 + c] = Math.round((from[c] as number) + ((to[c] as number) - (from[c] as number)) * t);
      }
    }
  }
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const PALETTES: [number, number, number][][] = [
  [[30, 80, 120], [120, 200, 190]],
  [[240, 150, 80], [90, 30, 70]],
  [[250, 220, 180], [90, 90, 120]],
  [[20, 30, 70], [10, 10, 30]],
  [[110, 90, 170], [240, 140, 120]],
  [[60, 160, 140], [30, 100, 170]],
];

// A JPEG from the PNG (sips ships with macOS), padded after the end-of-image marker to an
// exact byte count; decoders ignore trailing bytes.
function jpeg(path: string, size: number, palette: number, when: Date): void {
  const [from, to] = PALETTES[palette % PALETTES.length] as [number, number, number][];
  const tmp = join(tmpdir(), `ft-fixture-${process.pid}-${palette}.png`);
  writeFileSync(tmp, png(480, 320, from as [number, number, number], to as [number, number, number]));
  mkdirSync(dirname(path), { recursive: true });
  execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "70", tmp, "--out", path], { stdio: "ignore" });
  rmSync(tmp, { force: true });
  const body = readFileSync(path);
  const padded = Buffer.alloc(Math.max(size, body.length), 0);
  body.copy(padded);
  writeFileSync(path, padded);
  utimesSync(path, when, when);
}

function pdf(path: string, size: number, when: Date): void {
  const base = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 280]/Contents 4 0 R>>endobj\n4 0 obj<</Length 0>>stream\n\nendstream\nendobj\ntrailer<</Root 1 0 R>>\n%%EOF\n";
  const buf = Buffer.alloc(Math.max(size, base.length), 0x0a);
  buf.write(base);
  write(path, buf, when);
}

function setDirTime(path: string, when: Date): void {
  utimesSync(path, when, when);
}

// A folder without a given time gets the newest time of what it holds.
function settleDirTimes(dir: string, explicit: Map<string, Date>): Date {
  let newest = new Date(0);
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    const when = entry.isDirectory() ? settleDirTimes(path, explicit) : lstatSync(path).mtime;
    if (when > newest) newest = when;
  }
  const own = explicit.get(dir) ?? newest;
  setDirTime(dir, own);
  return own;
}

function freshTree(name: keyof typeof VERSIONS): string | null {
  const dir = join(ROOT, name);
  const stamp = join(dir, STAMP_NAME);
  if (existsSync(stamp) && readFileSync(stamp, "utf8").trim() === VERSIONS[name]) {
    console.log(`${name}: up to date`);
    return null;
  }
  if (existsSync(dir)) {
    spawnSync("chflags", ["-R", "nouchg", dir]);
    rmSync(dir, { recursive: true, force: true });
  }
  mkdirSync(dir, { recursive: true });
  return dir;
}

function finish(name: keyof typeof VERSIONS): void {
  writeFileSync(join(ROOT, name, STAMP_NAME), `${VERSIONS[name]}\n`);
  console.log(`${name}: done`);
}

// ---- lighthouse ---------------------------------------------------------------

type Entry = [name: string, size: number, when: Date];

function lighthouse(): void {
  const dir = freshTree("lighthouse");
  if (!dir) return;
  const root = join(dir, "Lighthouse");
  const put = (rel: string, size: number, when: Date, big = false) => {
    const path = join(root, rel);
    if (big) sparse(path, size, when);
    else write(path, textOfSize(`Lighthouse/${rel}`, size), when);
  };

  // Top-level files, as the Size-sorted list screenshot shows them.
  const top: Entry[] = [
    ["bun.lock", 325 * 1024, minutesAgo(51)],
    ["README.md", 147, minutesAgo(23)],
    ["package.json", 79, at("Oct 6 14:46")],
    ["CHANGELOG.md", 69, at("Oct 13 11:46")],
    ["CONTRIBUTING.md", 68, at("Mar 14 14:46")],
    ["docker-compose.yml", 65, at("Aug 5 14:46")],
    ["Makefile", 59, at("May 13 14:46")],
    ["LICENSE", 56, at("May 8 2025 14:46")],
    ["tsconfig.json", 50, at("Jul 5 14:46")],
  ];
  for (const [n, s, w] of top) put(n, s, w, s > 100_000);

  // app/src/components: the cut-and-paste screenshot.
  const components: Entry[] = [
    ["Avatar.jsx", 44, at("Oct 5 10:12")],
    ["DatePicker.jsx", 48, at("Oct 2 16:40")],
    ["PlacePicker.jsx", 49, at("Sep 29 09:05")],
    ["SearchField.jsx", 49, at("Sep 22 13:31")],
    ["SearchField.test.jsx", 85, at("Sep 22 13:35")],
    ["Toast.jsx", 43, at("Oct 11 14:28")],
    ["TripCard.jsx", 46, at("Sep 17 14:08")],
    ["TripCard.test.jsx", 76, at("Mar 14 14:41")],
    ["TripList.jsx", 46, at("Sep 24 14:24")],
    ["TripList.test.jsx", 76, at("Oct 1 14:23")],
    ["TripMap.jsx", 45, at("Oct 13 13:37")],
    ["TripMap.test.jsx", 73, at("Aug 30 14:08")],
    ["TripTimeline.jsx", 50, at("Oct 6 14:42")],
    ["TripTimeline.test.jsx", 88, at("Oct 8 14:30")],
  ];
  for (const [n, s, w] of components) put(`app/src/components/${n}`, s, w);
  const lib: Entry[] = [
    ["api.js", 120, at("Sep 3 11:00")],
    ["format.js", 96, at("Aug 18 15:20")],
    ["geo.js", 140, at("Sep 11 10:45")],
    ["storage.js", 88, at("Jul 22 17:05")],
  ];
  for (const [n, s, w] of lib) put(`app/src/lib/${n}`, s, w);
  const pages: Entry[] = [
    ["Home.jsx", 210, at("Oct 9 12:00")],
    ["Settings.jsx", 180, at("Sep 30 09:30")],
    ["Trip.jsx", 260, at("Oct 12 16:15")],
    ["Trips.jsx", 190, at("Oct 7 08:50")],
  ];
  for (const [n, s, w] of pages) put(`app/src/pages/${n}`, s, w);
  put("app/src/main.jsx", 130, at("Aug 2 10:00"));

  // app/dist and node_modules carry most of the 141 MB, as sparse files.
  put("app/dist/index.html", 420, minutesAgo(51));
  put("app/dist/assets/index.js", 4_200_000, minutesAgo(51), true);
  put("app/dist/assets/index.css", 38_000, minutesAgo(51));
  const modules: [string, number][] = [["react", 6], ["react-dom", 28], ["vite", 31], ["typescript", 62], ["eslint", 9]];
  for (const [pkg, mb] of modules) {
    put(`app/node_modules/${pkg}/package.json`, 300, at("Jul 5 14:46"));
    put(`app/node_modules/${pkg}/index.js`, 1_000, at("Jul 5 14:46"));
    put(`app/node_modules/${pkg}/lib/bundle.js`, mb * 1_000_000, at("Jul 5 14:46"), true);
  }
  put("app/tests/e2e/login.spec.js", 160, at("Sep 14 10:10"));
  put("app/tests/e2e/trips.spec.js", 240, at("Sep 28 11:20"));
  put("app/tests/fixtures/trips.json", 512, at("Sep 14 10:12"));
  put("app/tests/fixtures/user.json", 96, at("Sep 14 10:12"));

  put("data/exports/trips-2025.csv", 58_000_000, at("Jan 8 09:00"), true);
  put("data/exports/trips-2026.csv", 61_000_000, at("Oct 1 14:46"), true);
  put("data/exports/users.json", 2_400_000, at("Sep 1 08:00"), true);
  put("data/schema.sql", 1_800_000, at("Aug 12 10:30"), true);
  put("data/seed.sql", 31_000_000, at("Jul 20 16:40"), true);

  for (const [n, s, w] of [
    ["architecture.md", 1100, at("Oct 8 14:46")],
    ["api.md", 1000, at("Oct 8 14:30")],
    ["setup.md", 988, at("Sep 2 10:00")],
  ] as Entry[]) put(`docs/${n}`, s, w);
  put("infra/main.tf", 44, at("Sep 17 14:46"));
  put("infra/variables.tf", 40, at("Sep 17 14:40"));
  put("scripts/deploy.sh", 70, at("Sep 24 14:46"));
  put("scripts/seed.sh", 62, at("Sep 24 14:30"));

  put("mobile/ios/Lighthouse.xcodeproj/project.pbxproj", 51_000_000, minutesAgo(8 * 60 - 8), true);
  put("mobile/android/app-release.apk", 40_000_000, at("Oct 13 08:46"), true);
  put("mobile/README.md", 120, at("Oct 13 08:46"));

  // Pictures: every JPEG gets a different gradient.
  const photos: [string, number, Date][] = [
    ["Alpine lake", 121_000, at("Sep 24 14:00")], ["Arrabida coast", 118_000, at("Sep 24 14:02")],
    ["Biwa shore", 109_000, at("Sep 24 14:04")], ["Cape Point", 127_000, at("Sep 24 14:06")],
    ["Coast road", 125_000, at("Sep 24 14:07")], ["Desert dusk", 131_000, at("Sep 24 14:09")],
    ["Douro valley", 119_000, at("Sep 24 14:10")], ["Fjord morning", 124_000, at("Sep 24 14:11")],
    ["Fuji at dawn", 128_000, at("Sep 24 14:12")], ["Glenorchy road", 123_000, at("Sep 24 14:13")],
    ["Harbor sunrise", 126_000, at("Dec 14 2025 10:00")], ["Island noon", 117_000, at("Dec 14 2025 10:05")],
    ["Lake Wanaka", 129_000, at("Dec 14 2025 10:10")], ["Milford Sound", 133_000, at("Dec 14 2025 10:15")],
    ["Night ridge", 122_000, at("Dec 14 2025 10:20")], ["Old town evening", 130_000, at("Dec 14 2025 10:25")],
    ["Sintra hills", 120_000, at("Dec 14 2025 10:30")], ["Table Mountain dusk", 131_000, at("Jul 5 14:10")],
    ["Thingvellir", 116_000, at("Sep 24 14:14")], ["Valley mist", 102_000, at("Sep 24 14:08")],
    ["Vik beach", 142_000, at("Dec 14 2025 10:35")],
  ];
  photos.forEach(([n, s, w], i) => jpeg(join(root, "photos", `${n}.jpg`), s, i, w));
  pdf(join(root, "photos/Contact sheet.pdf"), 48_000, at("Sep 24 14:20"));
  for (const n of ["IMG_0412", "IMG_0413", "IMG_0414", "IMG_0415"]) {
    sparse(join(root, "photos/raw", `${n}.dng`), 5_800_000, at("Aug 30 14:46"));
  }

  // Design screens.
  const screens = ["home", "trip", "map", "settings", "onboarding"];
  screens.forEach((n, i) => {
    const path = join(root, "design/screens", `${n}.png`);
    write(path, png(390, 844, PALETTES[i % PALETTES.length]![0]!, PALETTES[i % PALETTES.length]![1]!), at("Oct 12 11:46"));
  });
  sparse(join(root, "design/brand.fig"), 24_000_000, at("Oct 12 11:46"));
  put("design/palette.md", 220, at("Oct 12 11:46"));

  // Folder times: the ones the screenshots show; the rest follow their newest child.
  const dirTimes: [string, Date][] = [
    ["app/src/components", at("Oct 13 13:37")], ["app/src/lib", at("Sep 11 10:45")],
    ["app/src/pages", at("Oct 12 16:15")], ["app/src", at("Oct 13 13:37")],
    ["app/dist/assets", minutesAgo(51)], ["app/dist", minutesAgo(51)],
    ["app/node_modules", at("Jul 5 14:46")], ["app/tests/e2e", at("Sep 28 11:20")],
    ["app/tests/fixtures", at("Sep 14 10:12")], ["app/tests", at("Sep 28 11:20")],
    ["app", minutesAgo(51)], ["data/exports", at("Oct 1 14:46")], ["data", at("Oct 1 14:46")],
    ["mobile/ios/Lighthouse.xcodeproj", at("Oct 13 08:46")], ["mobile/ios", at("Oct 13 08:46")],
    ["mobile/android", at("Oct 13 08:46")], ["mobile", at("Oct 13 08:46")],
    ["photos/raw", at("Aug 30 14:46")], ["photos", at("Aug 30 14:46")],
    ["design/screens", at("Oct 12 11:46")], ["design", at("Oct 12 11:46")],
    ["docs", at("Oct 8 14:46")], ["scripts", at("Sep 24 14:46")], ["infra", at("Sep 17 14:46")],
  ];
  const explicit = new Map(dirTimes.map(([rel, when]) => [join(root, rel), when]));
  explicit.set(root, minutesAgo(51));
  settleDirTimes(root, explicit);
  finish("lighthouse");
}

// ---- bench --------------------------------------------------------------------

const BENCH_STEMS = [
  "report", "IMG", "invoice", "notes", "Übersicht", "写真", "résumé", "Фото", "データ", "draft", "backup", "log",
];
const BENCH_EXTS = ["txt", "md", "jpg", "pdf", "csv", "json", "swift", "ts", "zip", "mov"];

function benchName(i: number, r: () => number): string {
  const stem = BENCH_STEMS[Math.floor(r() * BENCH_STEMS.length)];
  const ext = BENCH_EXTS[Math.floor(r() * BENCH_EXTS.length)];
  const n = Math.floor(r() * 100_000);
  // The index keeps names unique; the random number mixes sort orders (2 vs 10 vs 100).
  return `${stem} ${n} (${i}).${ext}`;
}

function benchFile(path: string, i: number): void {
  // One file in five has a few bytes, so sorting by size has something to do without
  // filling the disk with blocks.
  if (i % 5 === 0) writeFileSync(path, Buffer.alloc((i % 997) + 1, 0x61));
  else writeFileSync(path, "");
}

function bench(): void {
  const dir = freshTree("bench");
  if (!dir) return;
  const when = minutesAgo(3 * 24 * 60);
  for (const count of [300, 3000, 30_000, 100_000]) {
    const folder = join(dir, `files-${count}`);
    mkdirSync(folder, { recursive: true });
    const r = rng(count);
    for (let i = 0; i < count; i++) benchFile(join(folder, benchName(i, r)), i);
    setDirTime(folder, when);
  }
  // Deep tree: 20,000 folders (four children each, so about eight levels), ten files in each.
  const deep = join(dir, "deep");
  mkdirSync(deep, { recursive: true });
  const folders: string[] = [deep];
  for (let f = 0; f < 20_000; f++) {
    const path = f === 0 ? deep : join(folders[Math.floor((f - 1) / 4)] as string, `d${f}`);
    if (f > 0) {
      mkdirSync(path);
      folders.push(path);
    }
    for (let k = 0; k < 10; k++) benchFile(join(path, `f${k}.dat`), f * 10 + k);
  }
  finish("bench");
}

// ---- names --------------------------------------------------------------------

function names(): void {
  const dir = freshTree("names");
  if (!dir) return;
  const when = minutesAgo(10 * 24 * 60);
  const f = (rel: string, content = "x\n") => write(join(dir, rel), content, when);

  // APFS keeps the normalization a name was created with but treats both forms as one
  // name, so the two forms live in separate folders.
  const word = "Café Zoë Ångström";
  f(`nfc/${word.normalize("NFC")}.txt`);
  f(`nfd/${word.normalize("NFD")}.txt`);
  f("emoji/🎉 party 🎈.txt");
  f("emoji/👩‍👩‍👧‍👦 family.txt");
  f("emoji/🇳🇴 flag.txt");
  f("long/" + "a".repeat(251) + ".txt");
  f("long/" + "é".repeat(125) + ".md"); // 250 bytes plus extension
  f("dots/.hidden");
  f("dots/..double");
  f("dots/.config/settings.json", "{}\n");
  f("dots/visible.txt");
  f("localized/Applications/.localized", "");
  f("localized/Applications/readme.txt");
  f("spaces/ leading space.txt");
  f("spaces/trailing space .txt");
  f("spaces/a  double  space.txt");
  f("similar/Readme.md");
  f("similar/README.txt");
  f("similar/readme 2.txt");

  // Packages: a minimal .app bundle and a .key-style document package.
  f("packages/Sample.app/Contents/Info.plist",
    '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleName</key><string>Sample</string><key>CFBundleIdentifier</key><string>test.filetrail.sample</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n');
  f("packages/Sample.app/Contents/MacOS/Sample", "#!/bin/sh\n");
  f("packages/Sample.app/Contents/Resources/readme.txt");
  f("packages/Slides.key/Index/Document.iwa", "x".repeat(2048));
  f("packages/Slides.key/Data/image-1.png", "x".repeat(512));
  f("packages/Slides.key/metadata.plist", "<plist/>\n");

  // Links.
  mkdirSync(join(dir, "links/target folder"), { recursive: true });
  f("links/target folder/inside.txt");
  f("links/target.txt");
  symlinkSync("target folder", join(dir, "links/link to folder"));
  symlinkSync("target.txt", join(dir, "links/link to file"));
  symlinkSync("does-not-exist", join(dir, "links/broken link"));
  // A Finder alias, if Finder lets this process ask for one.
  try {
    execFileSync("osascript", ["-e", `tell application "Finder" to make alias file to (POSIX file "${join(dir, "links/target.txt")}" as alias) at (POSIX file "${join(dir, "links")}" as alias) with properties {name:"alias to file"}`], { stdio: "ignore", timeout: 15_000 });
  } catch {
    console.log("names: no Finder alias (osascript refused)");
  }

  // A locked file, and a file with a custom icon.
  f("locked/locked file.txt");
  spawnSync("chflags", ["uchg", join(dir, "locked/locked file.txt")]);
  f("icons/custom icon.txt");
  try {
    const iconPng = join(dir, "icons/.icon-source.png");
    writeFileSync(iconPng, png(128, 128, [220, 60, 60], [250, 200, 60]));
    execFileSync("osascript", ["-l", "JavaScript", "-e",
      `ObjC.import("AppKit"); const i = $.NSImage.alloc.initWithContentsOfFile("${iconPng}"); $.NSWorkspace.sharedWorkspace.setIconForFileOptions(i, "${join(dir, "icons/custom icon.txt")}", 0);`],
      { stdio: "ignore", timeout: 15_000 });
    rmSync(iconPng, { force: true });
  } catch {
    console.log("names: no custom icon");
  }
  finish("names");
}

// ---- main ---------------------------------------------------------------------

const wanted = process.argv.slice(2);
const all = { lighthouse, bench, names };
mkdirSync(ROOT, { recursive: true });
for (const [key, run] of Object.entries(all)) {
  if (wanted.length === 0 || wanted.includes(key)) run();
}
