// Port of packages/native-fs/src/native_copyfile.c, without N-API: Swift supplies the thread.
//
// `stop` is the caller's stop flag: once set, copyfile's status callback quits the copy between chunks
// and the copy fails with ECANCELED. Without it a large file can only be stopped once it has been copied
// in full. `copied` holds the bytes of data copied so far, so the caller can show progress inside a
// large file.
//
// Uses COPYFILE_ALL (preserve stat, xattrs, ACLs) | COPYFILE_CLONE (attempt CoW clone on APFS, fall back
// to full copy) | COPYFILE_EXCL (never replace an existing destination) | COPYFILE_DATA_SPARSE (keep the
// holes of sparse files).

#include "ft_copyfile.h"

#include <copyfile.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>

struct ft_copy_control {
    _Atomic int32_t stop;
    _Atomic int64_t copied;
};

typedef struct {
    ft_copy_control *control;
    /* 0, or the errno of a resource fork that couldn't be written, set by copy_status. */
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
   unless told to quit, so a move would then remove the original. The copy fails there as it does without
   a callback, with the write's own errno (quitting makes copyfile report ECANCELED), and leaves the file
   it made behind: callers remove a copy that failed. */
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
        if (what == COPYFILE_COPY_XATTR && !at_resource_fork(state)) {
            return COPYFILE_SKIP;
        }
        if (what == COPYFILE_COPY_XATTR) {
            w->errnum = errno != 0 ? errno : EIO;
        }
        return COPYFILE_QUIT;
    }
    return COPYFILE_CONTINUE;
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
        return copyfile(source, destination, NULL, flags) == 0 ? 0 : errno;
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
    int rc = copyfile(source, destination, state, flags);
    int saved = errno;
    copyfile_state_free(state);
    if (rc == 0) {
        return 0;
    }
    if (ft_copy_control_is_stopped(control)) {
        /* A copy told to quit reports ECANCELED, though some versions leave errno as it was: a stop
           asked for is a stop. */
        return ECANCELED;
    }
    /* Unless copy_status ended it over the resource fork and kept that write's errno. */
    return work.errnum != 0 ? work.errnum : saved;
}

/* Copies only a folder's own metadata (mode, flags, dates, extended attributes such as Finder tags and
   custom-icon flags, ACLs) onto a folder that already exists. Its contents are copied item by item by the
   caller; COPYFILE_RECURSIVE is deliberately not used. */
int ft_copy_metadata(const char *source, const char *destination) {
    return copyfile(source, destination, NULL, COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC) == 0 ? 0 : errno;
}
