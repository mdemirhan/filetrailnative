# Building File Trail

How to build File Trail from source, check a change and make a release.
What the app does is in the [README](../README.md) and [features.md](features.md);
the rules for working on the code are in [CLAUDE.md](../CLAUDE.md) and [principles.md](principles.md).

## Build from source

You only need this for changes that haven't been released yet, or to work on File Trail itself.
You need an Apple Silicon Mac and Xcode 27, and [Bun](https://bun.sh) to build the test fixtures (`bun tools/fixtures/generate.ts`; the tests that read them are skipped without them).
There is no Xcode project: File Trail is a Swift package with no dependencies beyond the system's frameworks and the system's libarchive.

```bash
scripts/build-app.sh
open "build/File Trail.app"
```

`scripts/build-app.sh debug` builds without optimizations.
These builds have an ad hoc signature, which changes with every build, so macOS asks again for access to Desktop, Documents and Downloads after each rebuild.

## Checking changes while working on the code

```bash
scripts/ci.sh                      # the app and the tests built with zero warnings, the tests, format lint
scripts/ci.sh --scope <filter>     # the same, with only the tests a swift test filter names
scripts/ci.sh --affected           # the same, with only the bundles the last commit and uncommitted changes reach
scripts/ci.sh --full               # all of it built from clean, and the release app as well
```

Each step prints one line, and the full logs are in `build/logs/`.

Open issues are in [state/known-issues.md](state/known-issues.md) and [state/battery.md](state/battery.md).

`scripts/ci.sh` leaves out the few tests that write large files to disk images (stopping a long copy, filling a disk), the tests that put real windows, menus and disks on screen, and a few slow release-only tests.
Run them with `FILETRAIL_LARGE_FILE_TESTS=1 scripts/ci.sh`, `FILETRAIL_GUI_TESTS=1 scripts/with-test-lock.sh swift test --filter GUITests` and `FILETRAIL_RELEASE_TESTS=1 scripts/ci.sh`;
`scripts/release.sh` runs all three.

## Making a signed app and a release

To make the app people download, under `build/release`:

```bash
scripts/make-release-app.sh --notarize   # signed and notarized, plus a ZIP and a disk image to share
scripts/make-release-app.sh              # signed with your Developer ID, not notarized
```

Signing uses the Developer ID Application certificate in `~/Documents/Apple Developer Certificates/developerID_application.cer` (or the one `MACOS_SIGN_CERT` names, or the keychain identity `MACOS_SIGN_IDENTITY` names), with its private key in your keychain.
Notarizing uses the `notarytool` keychain profile `filetrail` (or the one `MACOS_NOTARY_PROFILE` names);
create it once with `xcrun notarytool store-credentials filetrail --apple-id <email> --team-id <team ID>`.
`scripts/make-release-app.sh --help` has the details.

A version comes from git: a release is a commit tagged `vX.Y.Z`, and any other build is named after the last release before it, with how many commits it is past it (`0.1.0+dev.4`).
To make a release:

```bash
scripts/release.sh <major|minor|patch|X.Y.Z> --notes <file> [--yes] [--dry-run]
```

From a clean `main` that is already on GitHub, with the test fixtures built, it:

1. runs `scripts/ci.sh --full` with the large-file tests, the release-only tests and the fuzz tests at more cases, from a seed of the day;
2. runs the tests of real windows;
3. tags the commit it checked;
4. builds the notarized app and checks that its version is the tag and that nothing moved meanwhile;
5. pushes the tag, and makes a draft GitHub release with the disk image and the ZIP.

A failure before the push takes back the tag.
It stops if an earlier release was left unfinished, and it never publishes: read the draft over, then press Publish release on GitHub.

The notes are written for people before the release starts, in a Markdown file outside the checkout (or under `build/`), and named with `--notes <file>`.
They become both the draft's text and the tag's message, so `git show vX.Y.Z` keeps them.
The tag gets the file as it is when the commit is tagged: change the notes in the file, not on GitHub, or the tag and the release page will differ.
The first release is asked for by exact version, as there is nothing yet for `major`, `minor` or `patch` to count from.
`--dry-run` only says what it would release and what would stop it.

The frame times of scrolling are measured on demand, not by a release: `scripts/frame-times.sh` scrolls the List, Icons and Compact List in a real window and shows the numbers against an earlier run's file (`--against <file>`) or the last release measured on the same Mac model.
Load and power move them, so compare with a run made just before on the same Mac.

The README's screenshots come from `scripts/readme-screenshots.sh`, which shows the demo project in a throwaway home folder.
Each is a scene in `tools/capture/readme/`, and one run takes them all again;
the demo's photos are public-domain pictures kept in `tools/capture/readme/photos/`, with where each came from.

## How it is built

File Trail is a native Mac app written in Swift with AppKit, with a small C layer where the filesystem work has to be done the way macOS does it.

```text
Sources/FileTrail     The app's entry point
Sources/FTAppKit      The windows, views and menus
Sources/FTOperations  Copy, move and paste, the write journal, Undo
Sources/FTFileSystem  Listing, search, folder sizes, app state and other system services
Sources/FTFoundation  The logic that touches neither the disk nor the screen
Sources/CFileTrail    The C helpers
```

