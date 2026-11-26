# Plan: File Trail on the Mac App Store

What the app needs before it can be submitted, from a review of the code and the build as of 1.7.0 (24 November 2026).
Not started: the owner's decisions below come first.
The store page's text is in [app-store-listing.md](../app-store-listing.md).

## In short

Most of it is paperwork and a build script. One part is real work: **the Mac App Store takes only sandboxed apps** (App Review Guideline 2.4.5(i)), and a sandboxed app sees only the files and folders the user has given it.
A file browser has to ask for that access once and remember it, and a few features that reach outside the app (Empty Trash through Finder, mounting disk images with `hdiutil`, ejecting through Disk Arbitration) have to be tried in the sandbox and changed where it stops them.

Everything else already fits: File Trail makes no network connections, has no updater, no account, no login item, no root helper, no bundled tools and no third-party frameworks: search walks the disk inside the app.

The recommendation is to keep the Developer ID download as it is and add the App Store build beside it, made from the same code with an `APP_STORE` build flag where the two differ.
The download keeps every feature;
the App Store build gives up what the sandbox doesn't allow.

## Decisions for the owner

1. **Both channels, or the App Store only?**
   Recommended: both, as above.
   Only the App Store means the download becomes sandboxed too, and loses what the App Store build loses.
2. **Price.**
   Free, paid, or free with nothing to buy.
   Paid needs the Paid Apps agreement, tax and banking in App Store Connect.
   The MIT License allows any of them.
3. **How much access to ask for at first launch:** the whole startup disk (Macintosh HD), which covers search of the whole disk and every folder on it, or the Home folder, which feels smaller but leaves Applications, `/Library` and other disks to be granted later.
   Recommended: ask for Macintosh HD, with Home as the other choice in the same sheet.
4. **Empty Trash in the App Store build.**
   It needs a sandbox exception for Apple Events to Finder, which App Review may refuse.
   Recommended: ask for it with a reason in the review notes;
   if it is refused, the App Store build drops Empty Trash and offers to open the Trash in Finder.
5. **Opening disk images**, if `hdiutil` doesn't work in the sandbox: open them with DiskImageMounter as the app already does for an image with a password.
   Finder may then open a window of the disk, which `docs/decisions` set out to avoid.
6. **The same bundle ID for both channels** (`com.filetrail.native`).
   Recommended: yes.
   The two then can't be installed side by side under one name, and the App Store build keeps its settings in its sandbox container, apart from the download's, unless they are moved there (below).

## 1. Account and App Store Connect

You already have an Apple Developer Program membership (the Developer ID certificate needs one).
Add:

- [ ] **An explicit App ID** for `com.filetrail.native` in Certificates, Identifiers & Profiles.
  App Sandbox needs no capability ticked.
- [ ] **Certificates:** *Apple Distribution* (or *3rd Party Mac Developer Application*) to sign the app, and *Mac Installer Distribution* (*3rd Party Mac Developer Installer*) to sign the installer package.
  The Developer ID certificates can't be used for the store.
- [ ] **Provisioning profiles:** a *Mac App Store Connect* distribution profile for the upload, and a *macOS App Development* profile to run a sandboxed, store-signed build on this Mac while testing.
- [ ] **The app record** in App Store Connect (My Apps → +): platform macOS, name "File Trail" (check it is free), bundle ID, SKU and primary language as app-store-listing.md gives.
- [ ] **An App Store Connect API key** (Users and Access → Integrations) for uploading from the command line.
- [ ] **Agreements:** the Free Apps agreement is in place for every member;
  a paid app also needs the Paid Apps agreement, tax forms and banking.

## 2. The sandbox

### Folder access

Today the app reads any folder its user can, with the system's privacy prompts for Desktop, Documents, Downloads, removable and network volumes.
Sandboxed, it can open only what the user picked in an open panel, dropped on it, or opened with it, plus its own container.
That is done with:

- the entitlements `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`;
- **a first-launch sheet** that explains why, and an open panel aimed at Macintosh HD with a Grant Access button;
- **an app-scoped security-scoped bookmark** for each folder or disk granted, kept in the app's state, resolved at launch with `startAccessingSecurityScopedResource()`, and made again when it reports itself stale;
- **a folder outside the grants** showing a short "File Trail hasn't been given access to this folder" with a Grant Access… button, instead of an empty list or an error;
- **each external disk and server** granted the first time it is opened, with the same button: a grant of Macintosh HD is unlikely to reach the disks in `/Volumes` (to try).
  A list of the grants in Settings, to remove one.

Things to try once it is built, as these behave differently in the sandbox:

- [ ] Search, Go To, folder sizes, the folder tree and the Info panel across the whole disk once Macintosh HD is granted.
- [ ] Paths the app keeps and reads back at the next launch (recent folders, tabs to restore, folder views, the write journal and an interrupted Replace) reached through the bookmarks, not through access left over from the last run.
- [ ] Following a symbolic link or alias to somewhere not granted: it should say so, not fail silently (`Sources/FTFileSystem/System/Links.swift`).
- [ ] Protected places (Mail, Safari, other apps' containers) stay closed even with Macintosh HD granted unless the user gives File Trail Full Disk Access, as today.
- [ ] Files a sandboxed app writes are marked as quarantined by macOS.
  Copies, extracted archives and converted images will carry it, so an app or script extracted by File Trail is checked by Gatekeeper the first time it opens.
  Check that this is all it changes.

### Features to check or change

| Feature | Where | In the sandbox | What to do |
|---|---|---|---|
| Search | `Sources/CFileTrail/search.c` | The walk runs in the app, with the app's access. | Try a search of a granted disk, and of a folder dropped on the app. |
| Empty Trash | `Sources/FTFileSystem/System/TrashState.swift` (`NSAppleScript` to Finder) | Blocked without `com.apple.security.temporary-exception.apple-events` for `com.apple.finder`. | Owner's decision 4. Move to Trash itself (`trashItem`) is not affected. |
| The Trash location | `Sources/FTFoundation/Ranking/Places.swift`, `TrashFolders.swift` | `~/.Trash` is likely closed even with Home granted. | Try it. If closed, the sidebar's Trash opens Finder's Trash. |
| Opening disk images | `Sources/FTFileSystem/DiskImages/HdiutilProcess.swift` | `/usr/bin/hdiutil` runs inside the app's sandbox and is likely refused. | Try it. If refused, owner's decision 5. |
| Eject | `Sources/FTFileSystem/Volumes/VolumeEjector.swift` (Disk Arbitration) | Not known. | Try it on a USB disk, a disk image and a server. If refused, `NSWorkspace.unmountAndEjectDevice(at:)`. |
| Collation | `Sources/FTFoundation/Names/ICUCollator.swift` (`dlopen` of `libicucore`) | Allowed, but App Review's scan for non-public API may flag the ICU symbols. | Before the first upload, try a build through App Store Connect's validation. If flagged, Foundation's localized compare. |
| Kind names | `Sources/FTFileSystem/Icons/FileKind.swift` (`dlsym` of `LSCopyKindStringForURL`) | Allowed; the function is public but deprecated, and looked up by name. | Same check. If flagged, `URLResourceValues.localizedTypeDescription`. |
| Open With, Edit, Open in Terminal, Show in Finder, Share, Quick Look | `Sources/FTFileSystem/System/SystemActions.swift` | `NSWorkspace` and the system's panels pass the access on. | Try each once. |
| App state | `Sources/FTFileSystem/AppState/AppStatePaths.swift` | `Application Support` becomes the one in the container. | Nothing to change. For people moving from the download, a `container-migration.plist` in Resources moves the old state into the container at first launch. |
| Automation and capture | `Sources/FTAppKit/Automation/`, `--user-data-dir` | `screencapture` and folders outside the container are refused. | Test-only; leave it out of the App Store build with the build flag. |

### Entitlements of the App Store build

A new `Resources/FileTrail-AppStore.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
<!-- Only if Empty Trash stays (decision 4): -->
<key>com.apple.security.temporary-exception.apple-events</key>
<array><string>com.apple.finder</string></array>
<!-- Filled in from the provisioning profile: -->
<key>com.apple.application-identifier</key><string>TEAMID.com.filetrail.native</string>
<key>com.apple.developer.team-identifier</key><string>TEAMID</string>
```

No network entitlement: File Trail makes no connections, and servers are reached through the file system once macOS has mounted them.
`com.apple.security.files.all` and an absolute-path exception for `/` are not asked for: App Review refuses them for a file browser.

## 3. Build, sign and upload

A new `scripts/make-appstore-app.sh`, beside `scripts/make-release-app.sh`:

1. **Build** with the flag: `swift build -c release --product FileTrail -Xswiftc -DAPP_STORE`, then assemble the bundle as `scripts/build-app.sh` does.
2. **Info.plist** changes for this build:
   - `ITSAppUsesNonExemptEncryption` = `NO`;
   - `CFBundleVersion` higher with every upload, even of the same version: today it is the version itself (`scripts/version.sh --bundle`), so a second upload of 1.8.0 would be refused.
     The count of commits works (`git rev-list --count HEAD`);
   - `NSDesktopFolderUsageDescription` and the other folder prompts can stay as they are.
3. **Privacy manifest** `Contents/Resources/PrivacyInfo.xcprivacy`: no tracking, no data collected, and the reasons for the APIs Apple asks about, which the app uses:
   - file timestamps (`NSPrivacyAccessedAPICategoryFileTimestamp`): `DDA9.1` shown to the user, `3B52.1` of files the user gave access to;
   - disk space (`NSPrivacyAccessedAPICategoryDiskSpace`): `85F4.1` shown to the user, `E174.1` checked before writing;
   - system boot time (`NSPrivacyAccessedAPICategorySystemBootTime`, `ProcessInfo.systemUptime` in `AppClock.swift`): `35F9.1` elapsed time;
   - user defaults (`NSPrivacyAccessedAPICategoryUserDefaults`): `CA92.1` the app's own.
4. **Provisioning profile** copied to `Contents/embedded.provisionprofile`.
5. **Sign** with the Apple Distribution identity: the app with `FileTrail-AppStore.entitlements`.
   The hardened runtime is allowed but not required, and the app isn't notarized: Apple signs what the store ships.
6. **Package:** `productbuild --component "build/appstore/File Trail.app" /Applications --sign "3rd Party Mac Developer Installer: … (TEAMID)" build/appstore/FileTrail.pkg`.
7. **Validate and upload:** `xcrun altool --validate-app -f build/appstore/FileTrail.pkg -t macos --apiKey <key> --apiIssuer <issuer>`, then the same with `--upload-app`, or drop the package on the Transporter app.

No Xcode project is needed: the command-line tools are Apple's (Guideline 2.4.5(ii)).
The build is Apple silicon only, which the store accepts;
it lists the app as needing an Apple silicon Mac.

For testing on this Mac before any upload, the same script signs with the Apple Development identity and the development profile.
TestFlight for Mac takes the uploaded build to try before App Review, and is the place to go through the sandbox list in section 2.

`scripts/release.sh` can then make the App Store package beside the notarized download, from the same tag, and upload it after the owner's yes, as a draft release is published today.

## 4. Store page and pictures

- **Text:** [app-store-listing.md](../app-store-listing.md): name, subtitle, promotional text, keywords, description, review notes, all within Apple's limits.
- **Privacy policy:** [docs/privacy.md](../privacy.md), linked from the listing.
  The App Privacy answer is Data Not Collected.
- **Support URL:** the GitHub issues page.
- **Screenshots:** 16:10 at 2880 × 1800.
  Today's are 2224 × 1474 with a shadow, so they don't fit.
  The scenes in `tools/capture/readme/` can be taken again with the window at 1440 × 900 points on a Retina display, without a shadow, and a caption set above each (`scripts/appstore-screenshots.sh`, beside `scripts/readme-screenshots.sh`).
- **Icon:** `Resources/AppIcon.icns` has every size up to 512 × 512 @2x, which is what App Store Connect needs.
- **Age rating:** 4+.
  **Category:** Utilities, with Productivity second;
  Info.plist's `LSApplicationCategoryType` is to match the primary one (`public.app-category.utilities`).

## 5. What App Review looks at

| Guideline | File Trail |
|---|---|
| 2.4.5(i) sandboxed | Section 2. |
| 2.4.5(ii) built with Apple's tools, no installer of its own | The `swift` toolchain, `codesign` and `productbuild`. |
| 2.4.5(iii) self-contained, writes only where allowed | Yes: one bundle; state in the container. |
| 2.4.5(iv) nothing that starts at login or keeps running after quit | Yes: a search runs on the app's own threads and stops when it quits. |
| 2.4.5(v)/(vii) no updater of its own, no root | Yes: there is no update check, and nothing runs as root. |
| 2.5.1 public APIs only | The two `dlsym` lookups in section 2 are the ones to watch. |
| 2.3.7 metadata | No other app's name in the name, subtitle, keywords or description. |
| 4.2 enough function | A full file browser. |
| 5.1.1 privacy policy | docs/privacy.md. |

Temporary exceptions (Empty Trash) are asked about in the review: the reason goes in the review notes.

## 6. Order of work

1. App ID, certificates, profiles and the app record (section 1), so a build can be uploaded early.
2. `scripts/make-appstore-app.sh` with the sandbox entitlements and no other change, signed for development, to see what breaks: the list in section 2 is the guess, this is the answer.
3. The folder-access sheet, the bookmarks and the Grant Access… placeholder.
4. The changes the tries in step 2 call for, behind `APP_STORE`.
5. Validation in App Store Connect (the private-API scan), then TestFlight.
6. Screenshots, the listing, the privacy answers, and submission.
