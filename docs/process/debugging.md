# Debugging notes

What was learned finding two kinds of trouble, kept so it isn't found out again.

## A test run that stalls, slows or fails now and then

Don't run it again to see whether it passes. Look once and find the cause:

- The logs of a failed run are kept in `build/logs/failed-*`, with how long each test took. Many unrelated tests that took the same time waited on one shared thing, not on themselves.
- `scripts/ci.sh` samples a test process whose log stops for 10 s into `build/logs/bundles/<bundle>.stall-N.txt`: where every thread waits. By hand, `sample` the `swiftpm-testing-helper`.
- A full run of more than about a minute, with nothing else running, means something is wrong.
- Only one `scripts/ci.sh` or `swift test` runs at a time on one Mac; several at once stall each other (see `CLAUDE.md`).

Three causes found so far, worth a look first:

- **Swift's shared threads held by work that blocks.** Tests that held a stand-in disk on those threads stalled a whole bundle for 60 s. Work that can block goes through `BlockingWork.run`.
- **The main actor of the app bundle's tests kept busy.** Guards that ran seconds of CPU on the main actor made every wait on the clock there (20 s then) a coin toss. Speed guards of code with no views belong in `FTFoundationTests`; a wait on the main actor only stops a hang (60 s), it doesn't check speed. To see who holds it, sample the bundle's main thread and add up the samples by test.
- **A resource fork written through `file/..namedfork/rsrc` isn't in the file yet.** macOS writes it into a stand-in file and copies it into the file at the open file's last close, and a process spawned by another thread (`ditto`, `hdiutil`) holds the open file for a moment, until its exec drops the close-on-exec descriptors. When the child's close was the last, `getxattr` found no fork for a while after the write had returned: a check of the fork saw a source without one (`ResourceForkCheckTests`, 2026-11-17). Eight threads spawning `/bin/sleep` in a loop brought it back 11 times in 5,000 writes, and never without them; a `dup` held open shows it every time. Tests write a fork with `setxattr` (`NativeTestFiles.write`), which has put it in the file when it returns. The copy that once reported success with no fork on a full disk (`docs/decisions/file-operations.md`) was probably this too: its source's fork was written the same way, beside tests that mount disk images, and measured only after the copy.

## A Desktop, Documents or Downloads permission question

A debug build signed with the Developer ID (as `scripts/readme-screenshots.sh` signs it) has File Trail's own permissions: macOS takes it for the same app. So a question that was answered once doesn't come again until the answers are reset.

- `tccutil reset SystemPolicyDesktopFolder com.filetrail.native` (and `SystemPolicyDocumentsFolder`, `SystemPolicyDownloadsFolder`). This resets every copy of the app on the Mac, the installed one too: say so before doing it.
- Start the app with `open -n`, so that macOS takes File Trail for the one asking, not the shell.
- While the question waits, `sample <pid>`: the thread waiting in the kernel is the read that asked.
- The question's words can't be read without screen recording; ask the owner what it says.

What it was, the one time: reading the Finder tags (`getxattr`) of `~/Desktop` to show the home folder. Reading a protected folder's own extended attributes counts as going into it, not only reading what is in it.
