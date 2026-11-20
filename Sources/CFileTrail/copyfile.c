// The copyfile(3) calls of the write engine, for Swift, which supplies the thread.
//
// `stop` is the caller's stop flag: once set, copyfile's status callback quits the copy between chunks
// and the copy fails with ECANCELED. Without it a large file can only be stopped once it has been copied
// in full. `copied` holds the bytes of data copied so far, so the caller can show progress inside a
// large file. `trace`, in debug builds only, says what copyfile reported, for a test that failed to name it.
//
// Uses COPYFILE_ALL (preserve stat, xattrs, ACLs) | COPYFILE_CLONE (attempt CoW clone on APFS, fall back
// to full copy) | COPYFILE_EXCL (never replace an existing destination) | COPYFILE_DATA_SPARSE (keep the
// holes of sparse files).

#include "ft_copyfile.h"

#include <copyfile.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/xattr.h>

struct ft_copy_control {
    _Atomic int32_t stop;
    _Atomic int64_t copied;
#ifdef DEBUG
    /* What copyfile reported: each failed step, then what it returned and what the copy made of it. Written by the
       thread running the copy, read once the copy returned. Only the tests read it, so a release build has none. */
    char trace[512];
    size_t trace_length;
#endif
};

typedef struct {
    ft_copy_control *control;
    /* 0, or the errno of an extended attribute whose failed write ended the copy (the resource fork, or one the disk
       had no room for), set by copy_status. */
    int errnum;
} copy_work_t;

ft_copy_control *ft_copy_control_create(void) {
    ft_copy_control *control = calloc(1, sizeof(ft_copy_control));
    if (control != NULL) {
        atomic_init(&control->stop, 0);
        atomic_init(&control->copied, 0);
    }
    return control;
}

void ft_copy_control_free(ft_copy_control *control) { free(control); }

void ft_copy_control_stop(ft_copy_control *control) {
    atomic_store_explicit(&control->stop, 1, memory_order_relaxed);
}

int ft_copy_control_is_stopped(const ft_copy_control *control) {
    return atomic_load_explicit(&((ft_copy_control *)control)->stop, memory_order_relaxed) != 0;
}

#ifdef DEBUG
const char *ft_copy_control_trace(const ft_copy_control *control) { return control->trace; }

/* Adds to the trace while it has room; what doesn't fit is cut off. */
static void add_trace(ft_copy_control *control, const char *format, ...) {
    size_t room = sizeof(control->trace) - control->trace_length;
    if (room <= 1) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    int written = vsnprintf(control->trace + control->trace_length, room, format, arguments);
    va_end(arguments);
    if (written > 0) {
        control->trace_length += (size_t)written < room ? (size_t)written : room - 1;
    }
}
#else
const char *ft_copy_control_trace(const ft_copy_control *control) {
    (void)control;
    return "";
}
#endif

int64_t ft_copy_control_copied(const ft_copy_control *control) {
    return atomic_load_explicit(&((ft_copy_control *)control)->copied, memory_order_relaxed);
}

void ft_copy_control_set_copied(ft_copy_control *control, int64_t copied) {
    atomic_store_explicit(&control->copied, copied, memory_order_relaxed);
}

/* Whether the extended attribute copyfile is at is the resource fork. */
static bool at_resource_fork(copyfile_state_t state) {
    const char *name = NULL;
    return copyfile_state_get(state, COPYFILE_STATE_XATTRNAME, &name) == 0 && name != NULL &&
           strcmp(name, XATTR_RESOURCEFORK_NAME) == 0;
}

/* Whether a write failed for lack of room or over the disk itself (a full FAT disk says EIO on older macOS), not
   because the disk refuses what was written. */
static bool no_room_or_disk_error(int errnum) { return errnum == ENOSPC || errnum == EDQUOT || errnum == EIO; }

/* Called by copyfile(3) between chunks of data and between the parts of a file (data, extended
   attributes, ...): stops the copy once the caller has asked it to, but only while the data is being
   copied. copyfile removes the file it created when told to quit there; told to quit at the extended
   attributes, which it copies first (most files have com.apple.provenance), it leaves an empty file
   behind. A stop asked for then is seen at the first chunk of data.
   copyfile also calls it when a step fails (stage COPYFILE_ERR), and there CONTINUE means "try that
   again": a write that keeps failing (the disk is full, or was unplugged) would be retried forever. A
   failed data write ends the copy with its error instead; a failed extended attribute is skipped, as
   metadata the destination may not take (a disk that refuses com.apple.provenance). Except the resource
   fork: that is the file's content for old Mac files, and copyfile goes on as if it had been copied whole
   unless told to quit, so a move would then remove the original. And except an attribute the disk had no
   room for, or failed to write: the disk would have taken it, so the copy isn't done without it (on a
   full FAT or exFAT disk the "._" file can't be made, an empty file's data needs no room, and a move
   would remove the original with its tags and comments). The copy fails there as it does without a
   callback, with the write's own errno (quitting makes copyfile report ECANCELED), and leaves the file it
   made behind: callers remove a copy that failed. */
static int copy_status(int what, int stage, copyfile_state_t state, const char *src, const char *dst,
                       void *ctx) {
    (void)src;
    (void)dst;
    copy_work_t *w = (copy_work_t *)ctx;
    if (what == COPYFILE_COPY_DATA && ft_copy_control_is_stopped(w->control)) {
        return COPYFILE_QUIT;
    }
    if (what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS) {
        off_t copied = 0;
        if (copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied) == 0) {
            ft_copy_control_set_copied(w->control, (int64_t)copied);
        }
    }
    if (stage == COPYFILE_ERR) {
        int errnum = errno;
        bool skip = what == COPYFILE_COPY_XATTR && !at_resource_fork(state) && !no_room_or_disk_error(errnum);
#ifdef DEBUG
        const char *name = NULL;
        if (what == COPYFILE_COPY_XATTR) {
            copyfile_state_get(state, COPYFILE_STATE_XATTRNAME, &name);
        }
        add_trace(w->control, "step %d%s%s failed with errno %d, %s; ", what, name != NULL ? " " : "",
                  name != NULL ? name : "", errnum, skip ? "skipped" : "quit");
#endif
        if (skip) {
            return COPYFILE_SKIP;
        }
        if (what == COPYFILE_COPY_XATTR) {
            w->errnum = errnum != 0 ? errnum : EIO;
        }
        return COPYFILE_QUIT;
    }
    return COPYFILE_CONTINUE;
}

/* The resource fork is an old Mac file's content, and copyfile has been seen to report a copy as done with none in
   it (once, writing to a full disk while the Mac was busy): a move would then remove the original with it. So a
   copy reported as done is checked for it, by its size. */
/* What the fork's sizes read before it is checked: getxattr gives -1 at the least. */
#define FORK_NOT_CHECKED ((ssize_t)-2)

static int check_resource_fork(const char *source, const char *destination, ssize_t *wanted_out,
                               ssize_t *found_out) {
    ssize_t wanted = getxattr(source, XATTR_RESOURCEFORK_NAME, NULL, 0, 0, XATTR_NOFOLLOW);
    *wanted_out = wanted;
    *found_out = -1;
    if (wanted <= 0) {
        return 0;
    }
    ssize_t found = getxattr(destination, XATTR_RESOURCEFORK_NAME, NULL, 0, 0, XATTR_NOFOLLOW);
    *found_out = found;
    if (found == wanted) {
        return 0;
    }
    struct statfs disk;
    if (statfs(destination, &disk) == 0 && (uint64_t)disk.f_bavail * disk.f_bsize < (uint64_t)wanted) {
        return ENOSPC;
    }
    return EIO;
}

int ft_check_resource_fork(const char *source, const char *destination) {
    ssize_t wanted, found;
    return check_resource_fork(source, destination, &wanted, &found);
}

/* copyfile failed without saying why: it can leave errno as it was, and the callback saw no write of the fork fail.
   It is a failure all the same, never a copy that is done: the fork's check says why when the fork is short, EIO
   otherwise. */
static int unexplained_failure(const char *source, const char *destination, ssize_t *wanted, ssize_t *found) {
    int errnum = check_resource_fork(source, destination, wanted, found);
    return errnum != 0 ? errnum : EIO;
}

int ft_copyfile(const char *source, const char *destination, ft_copy_control *control) {
    /* NOFOLLOW_SRC copies a symlink as a symlink instead of its target's data.
       EXCL fails with EEXIST instead of writing over an item that appeared at the destination: callers
       always copy to a name they expect to be free.
       DATA_SPARSE keeps the holes of a sparse file (disk images, VM disks) instead of writing them out
       as zeros, which can fill the destination disk. */
    const copyfile_flags_t flags =
        COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL | COPYFILE_DATA_SPARSE;
    if (control == NULL) {
        errno = 0;
        if (copyfile(source, destination, NULL, flags) == 0) {
            return ft_check_resource_fork(source, destination);
        }
        ssize_t wanted, found;
        return errno != 0 ? errno : unexplained_failure(source, destination, &wanted, &found);
    }
    if (ft_copy_control_is_stopped(control)) {
        return ECANCELED;
    }
    copyfile_state_t state = copyfile_state_alloc();
    if (state == NULL) {
        return ENOMEM;
    }
    copy_work_t work = {.control = control, .errnum = 0};
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, (const void *)&copy_status);
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, (const void *)&work);
    errno = 0;
    int rc = copyfile(source, destination, state, flags);
    int saved = errno;
    copyfile_state_free(state);
    /* The fork's sizes, when it was checked, for the trace. */
    ssize_t wanted = FORK_NOT_CHECKED;
    ssize_t found = FORK_NOT_CHECKED;
    int result;
    if (rc == 0) {
        result = check_resource_fork(source, destination, &wanted, &found);
    } else if (ft_copy_control_is_stopped(control)) {
        /* A copy told to quit reports ECANCELED, though some versions leave errno as it was: a stop
           asked for is a stop. */
        result = ECANCELED;
    } else if (work.errnum != 0) {
        /* copy_status ended it over an extended attribute and kept that write's errno. */
        result = work.errnum;
    } else if (saved != 0) {
        result = saved;
    } else {
        result = unexplained_failure(source, destination, &wanted, &found);
    }
#ifdef DEBUG
    add_trace(control, "copyfile returned %d with errno %d; ", rc, saved);
    if (wanted == FORK_NOT_CHECKED) {
        add_trace(control, "the fork not checked; ");
    } else {
        add_trace(control, "the copy's fork %zd of the source's %zd bytes; ", found, wanted);
    }
    add_trace(control, "the copy returns %d", result);
#endif
    return result;
}

/* copyfile for a folder's own metadata: 0, or why it failed. It can fail and leave errno as it was: that is a
   failure all the same (EIO), never metadata that was copied, after which a move would remove the original folder. */
static int copy_metadata(const char *source, const char *destination, copyfile_flags_t flags) {
    errno = 0;
    if (copyfile(source, destination, NULL, flags) == 0) {
        return 0;
    }
    return errno != 0 ? errno : EIO;
}

/* Copies only a folder's own metadata (mode, flags, dates, extended attributes such as Finder tags and
   custom-icon flags, ACLs) onto a folder that already exists. Its contents are copied item by item by the
   caller; COPYFILE_RECURSIVE is deliberately not used. */
int ft_copy_metadata(const char *source, const char *destination) {
    return copy_metadata(source, destination, COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC);
}

/* As ft_copy_metadata, for the folder of an app copied on its own: a source in quarantine gives the copy that
   quarantine with QTN_FLAG_DO_NOT_TRANSLOCATE (COPYFILE_RUN_IN_PLACE), so the app runs from where it was put.
   It stays in quarantine, so Gatekeeper still checks it when it is first opened. */
int ft_copy_metadata_run_in_place(const char *source, const char *destination) {
    return copy_metadata(source, destination, COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_RUN_IN_PLACE);
}
