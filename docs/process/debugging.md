# Debugging notes

What was learned finding two kinds of trouble, kept so it isn't found out again.

## A test run that stalls, slows or fails now and then

Don't run it again to see whether it passes.
Look once and find the cause:

- The logs of a failed run are kept in `build/logs/failed-*`, with how long each test took.
  Many unrelated tests that took the same time waited on one shared thing, not on themselves.
- `scripts/ci.sh` samples a test process whose log stops for 10 s into `build/logs/bundles/<bundle>.stall-N.txt`: where every thread waits.
  By hand, `sample` the `swiftpm-testing-helper`.
- A full run of more than about a minute, with nothing else running, means something is wrong.
- Only one test run goes on at a time on one Mac;
  several at once stall each other.
  `scripts/ci.sh` and a release wait for each other by one lock every checkout shares (`scripts/lib/test-lock.sh`), and `scripts/with-test-lock.sh` puts a `swift test` behind it (see `CLAUDE.md`).
  Every process of a failed run stalled at the same moment points here first: a run of something else beside it.

Six causes found so far, worth a look first:

- **The keys or the mouse button of whoever is at the Mac.**
  Code that reads the live input state (`NSEvent.modifierFlags`, `NSEvent.pressedMouseButtons`) sees what someone typing or clicking elsewhere holds while the tests run.
  A held Option opened the Info panel's Open With as Always Open With (2026-11-21);
  a held mouse button made the Previews pane take a scroll for a drag's and its listings select nothing, which failed three Previews tests now and then, one of them in a release's run (2026-11-21): the stall samples showed an idle app and the test polling, nothing stuck.
  Such a read goes through a seam a test can replace (`InfoController.optionHeld`, `PreviewsViewController.mouseButtonHeld`, which `WindowlessScope` sets to up), and a failure that comes only while someone uses the Mac points here.
  An event a test makes reads it too: a `CGEvent` made without a source carries the keys held as it is made.
  With Shift held, a line-based wheel notch comes sideways (`scrollingDeltaY` 0), which failed `aWheelNotchMovesTheCompactListFortySideways` once in a run (2026-11-26): 20,000 notches made in the test's own harness all came as one line, and the same notch made with Shift came as 0 with the list unmoved, the failure's numbers.
  Tests make their events from a source of their own (`systemKeyEvent`, `systemWheelEvent`).
- **Swift's shared threads held by work that blocks.**
  Tests that held a stand-in disk on those threads stalled a whole bundle for 60 s.
  Work that can block goes through `BlockingWork.run`.
- **The main actor of the app bundle's tests kept busy.**
  Guards that ran seconds of CPU on the main actor made every wait on the clock there (20 s then) a coin toss.
  Speed guards of code with no views belong in `FTFoundationTests`;
  a wait on the main actor only stops a hang (60 s), it doesn't check speed.
  To see who holds it, sample the bundle's main thread and add up the samples by test.
- **A resource fork written through `file/..namedfork/rsrc` isn't in the file yet.** macOS writes it into a stand-in file and copies it into the file at the open file's last close, and a process spawned by another thread (`ditto`, `hdiutil`) holds the open file for a moment, until its exec drops the close-on-exec descriptors.
  When the child's close was the last, `getxattr` found no fork for a while after the write had returned: a check of the fork saw a source without one (`ResourceForkCheckTests`, 2026-11-17).
  Eight threads spawning `/bin/sleep` in a loop brought it back 11 times in 5,000 writes, and never without them;
  a `dup` held open shows it every time.
  Tests write a fork with `setxattr` (`NativeTestFiles.write`), which has put it in the file when it returns.
  The copy that once reported success with no fork on a full disk (`docs/decisions/file-operations.md`) was probably this too: its source's fork was written the same way, beside tests that mount disk images, and measured only after the copy.
- **A macOS update that changes when AppKit tells the app something.**
  From macOS 27.2.1 (installed here on 2026-11-23), a drag tells its source it has ended through the main dispatch queue, where before it told it within the turn of the run loop that took the button-up.
  The drag test, which ends a real drag with a button-up it posts and spins the main run loop of its own while it waits, did so from inside the main queue's work, which a nested run doesn't serve: the drag ended at once but was told only when the test gave up 5 s later, and a test beside it waiting on the main thread timed out with it (`FileDragTests`, `DirectoryServiceStallTests`, 2026-11-24).
  The test now waits between its own runs, so the main queue can tell it.
  Two unrelated tests failing every time from one day to the next, with nothing changed in their code, points at the system: `softwareupdate --history` says when it changed.
- **A system daemon that quits between two requests of one job, and launchd's throttle on starting it again.**
  Quick Look makes a Word document's page in quicklookd when asked, and the viewer's web view asks quicklookd for the page as it loads, a moment later.
  In a full run quicklookd now and then quit cleanly (`exit(0)`) 0.3 to 0.5 s after it started, before the page's ask: its launchd job (`/System/Library/LaunchAgents/com.apple.quicklook.plist`) allows a pressured exit and has a `ThrottleInterval` of 1, so the ask waited a second for a new quicklookd, which had no page to give.
  The page loaded empty and stayed so, and `aWordDocumentsTextCanBeSelected` failed with `page ""` (`TextViewerWindowTests`, three times on 2026-11-25, one of them the 1.8.0 release's check).
  The stall samples showed WebKit's process throttle at work, which looked like the web process kept from drawing;
  it wasn't: the web process answered every script, and its page held nothing.
  What showed it was the unified log, which keeps a test process's WebKit lines and the web process's own for a few days: `/usr/bin/log show --start … --end … --predicate 'processID == <pid>'` around the failure had the page's main resource finish with `length=0`, and launchd's lines (`--predicate 'process == "launchd"'`, grepped for `com.apple.quicklook`) had quicklookd's exit, `service spawn deferred by 1 seconds due to throttle`, and the new one.
  Those three came together before each of the three failures and at no other time that day;
  otherwise quicklookd lived seconds.
  Stopping quicklookd as the web view appears, before its ask (`pkill -9 -x quicklookd` from a scratch test polling for the web view every millisecond), empties the page every time;
  stopping it later, once the page has its answer, does nothing.
  Why quicklookd quit so early in a full run wasn't found: the log has no sign of memory pressure at those moments, and a single test beside every core kept busy never brought it on.
  A page that comes empty is now asked of Quick Look again (`QuickLookHost.checkEmptyPage`), as the app on a busy Mac can meet it too;
  `aWordDocumentsPageThatComesEmptyIsAskedForAgain` empties the page itself to stand in for it, as stopping the user's quicklookd in a run would stop it for every other test process too.

## A Desktop, Documents or Downloads permission question

A debug build signed with the Developer ID (as `scripts/readme-screenshots.sh` signs it) has File Trail's own permissions: macOS takes it for the same app.
So a question that was answered once doesn't come again until the answers are reset.

- `tccutil reset SystemPolicyDesktopFolder com.filetrail.native` (and `SystemPolicyDocumentsFolder`, `SystemPolicyDownloadsFolder`).
  This resets every copy of the app on the Mac, the installed one too: say so before doing it.
- Start the app with `open -n`, so that macOS takes File Trail for the one asking, not the shell.
- While the question waits, `sample <pid>`: the thread waiting in the kernel is the read that asked.
- The question's words can't be read without screen recording;
  ask the owner what it says.

What it was, the one time: reading the Finder tags (`getxattr`) of `~/Desktop` to show the home folder.
Reading a protected folder's own extended attributes counts as going into it, not only reading what is in it.
