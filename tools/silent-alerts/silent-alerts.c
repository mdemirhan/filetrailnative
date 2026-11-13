// The test processes scripts/ci.sh starts load this library (DYLD_INSERT_LIBRARIES), so they play no alert sounds. Some
// tests press keys that nothing handles, or the key of a menu item that is turned off, and AppKit beeps for those as it
// would in the app.
//
// Only the test process keeps it: the variable is taken out of the environment as the process starts, so what a test
// launches doesn't load it. With FILETRAIL_ALERTS_LOG set to a file, each sound that would have played is written there
// with the calls that led to it.

#include <AudioToolbox/AudioToolbox.h>
#include <execinfo.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void note(const char *kind, SystemSoundID sound) {
    const char *path = getenv("FILETRAIL_ALERTS_LOG");
    if (path == NULL || path[0] == '\0') return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char head[96];
    int length = snprintf(head, sizeof head, "=== %s %u in process %d\n", kind, (unsigned)sound, getpid());
    if (length > 0) write(fd, head, (size_t)length);
    void *frames[64];
    backtrace_symbols_fd(frames, backtrace(frames, 64), fd);
    close(fd);
}

static void playAlertSound(SystemSoundID sound) { note("alert sound", sound); }

static void playAlertSoundWithCompletion(SystemSoundID sound, void (^done)(void)) {
    note("alert sound", sound);
    if (done) done();
}

static void playSystemSound(SystemSoundID sound) { note("system sound", sound); }

static void playSystemSoundWithCompletion(SystemSoundID sound, void (^done)(void)) {
    note("system sound", sound);
    if (done) done();
}

typedef struct {
    const void *replacement;
    const void *replaced;
} Interpose;

__attribute__((used)) static const Interpose interposed[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)playAlertSound, (const void *)AudioServicesPlayAlertSound},
    {(const void *)playAlertSoundWithCompletion, (const void *)AudioServicesPlayAlertSoundWithCompletion},
    {(const void *)playSystemSound, (const void *)AudioServicesPlaySystemSound},
    {(const void *)playSystemSoundWithCompletion, (const void *)AudioServicesPlaySystemSoundWithCompletion},
};

// `swift test` passes the variable down through the toolchain's own processes to the one that runs the tests: that one
// takes it out.
__attribute__((constructor)) static void keepToTheTestProcess(void) {
    const char *name = getprogname();
    if (strcmp(name, "swiftpm-testing-helper") == 0 || strcmp(name, "xctest") == 0) unsetenv("DYLD_INSERT_LIBRARIES");
}
