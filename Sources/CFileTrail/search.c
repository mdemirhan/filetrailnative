// The walk a search runs on, for Swift, which decides what each item it passes is.
//
// The folders still to list are a stack on one lock, which a few worker threads take from. Each lists its
// folder with readdir(3), which reads the folder's own entries (each name and its type) and not the items
// themselves: a search passes far more items than it finds, so nothing more is read of one until it
// matches. Each file and folder passed goes to the match callback, each match then to the keep callback,
// and each folder to the stack when the walk goes deeper. Taken last in, first out, the walk goes down
// before it goes across, so the stack stays short.
//
// What is kept is what a search lists: files and folders. Symbolic links, devices, sockets and pipes are
// passed over, and no link is followed into, as the search has always done. Hidden items (a name starting
// with a dot, or the flag that hides one) and everything inside a hidden folder are left out unless asked
// for. The flag is read of an item only once it has matched, and of a folder when it is opened. Folders on
// other disks are walked into, as anything mounted below the folder searched is part of it, except, for a
// search of "/", /Volumes (other disks are searched from their own top) and /System/Volumes (the data
// volume is already reached through the firmlinks).
//
// A folder that can't be opened or listed for a reason other than being gone is noted, and the walk goes
// on: what is in it isn't searched. Only the folder searched not being listable at all ends the walk with
// an error.

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "CFileTrail.h"
#include "ft_search.h"

#define SEARCH_MAX_THREADS 32
#define SEARCH_DEFAULT_THREADS 4

/* ── The folders still to list ───────────────────────────────────── */

typedef struct search_node {
    char *path; /* owned */
    size_t length;
    struct search_node *next;
} search_node;

struct ft_search {
    char *root_path;
    ft_search_options options;
    ft_search_match match;
    ft_search_keep keep;
    void *context;

    pthread_mutex_t lock;
    pthread_cond_t cond;
    search_node *head;
    int active;   /* workers listing a folder; under the lock */
    int finished; /* nothing left to list; under the lock */

    atomic_int stopped;
    atomic_int failed; /* out of memory */
    atomic_int unreadable;
    atomic_int root_errno;
    int respells; /* the disk searched lists names otherwise than it holds them */
    dev_t root_dev;
    int run; /* ft_search_run was called */
};

static int search_should_stop(ft_search *search) {
    return atomic_load_explicit(&search->stopped, memory_order_relaxed) ||
           atomic_load_explicit(&search->failed, memory_order_relaxed);
}

static void search_wake_all(ft_search *search) {
    pthread_mutex_lock(&search->lock);
    pthread_cond_broadcast(&search->cond);
    pthread_mutex_unlock(&search->lock);
}

static void search_stop(ft_search *search) {
    atomic_store(&search->stopped, 1);
    search_wake_all(search);
}

static void search_fail(ft_search *search) {
    atomic_store(&search->failed, 1);
    search_wake_all(search);
}

/* Takes ownership of `path`, freed when it can't be taken. */
static int search_push(ft_search *search, char *path, size_t length) {
    search_node *node = malloc(sizeof(search_node));
    if (!node) {
        free(path);
        return 0;
    }
    node->path = path;
    node->length = length;
    pthread_mutex_lock(&search->lock);
    node->next = search->head;
    search->head = node;
    pthread_cond_signal(&search->cond);
    pthread_mutex_unlock(&search->lock);
    return 1;
}

/* The next folder to list, or NULL when the walk is over (all listed, or stopped). */
static search_node *search_pop(ft_search *search) {
    pthread_mutex_lock(&search->lock);
    for (;;) {
        if (search_should_stop(search) || search->finished) {
            pthread_mutex_unlock(&search->lock);
            return NULL;
        }
        if (search->head) {
            search_node *node = search->head;
            search->head = node->next;
            search->active++;
            pthread_mutex_unlock(&search->lock);
            return node;
        }
        if (search->active == 0) {
            search->finished = 1;
            pthread_cond_broadcast(&search->cond);
            pthread_mutex_unlock(&search->lock);
            return NULL;
        }
        pthread_cond_wait(&search->cond, &search->lock);
    }
}

static void search_done_with_folder(ft_search *search) {
    pthread_mutex_lock(&search->lock);
    search->active--;
    if (search->active == 0 && search->head == NULL) {
        pthread_cond_broadcast(&search->cond);
    }
    pthread_mutex_unlock(&search->lock);
}

/* ── Opening a folder ────────────────────────────────────────────── */

#define SEARCH_OPEN_FLAGS (O_RDONLY | O_DIRECTORY | O_NOFOLLOW)

/* Opens the folder at `path`, which a path too long for one call is opened a part at a time,
   each part relative to the one before, so no folder is too deep to search. */
static int search_open_path(const char *path) {
    if (strlen(path) < PATH_MAX) return open(path, SEARCH_OPEN_FLAGS);
    int at = AT_FDCWD;
    const char *rest = path;
    while (strlen(rest) >= PATH_MAX) {
        const char *cut = rest + PATH_MAX - 1;
        while (cut > rest && *cut != '/') cut--;
        if (cut == rest) {
            if (at != AT_FDCWD) close(at);
            errno = ENAMETOOLONG;
            return -1;
        }
        char part[PATH_MAX];
        size_t part_length = (size_t)(cut - rest);
        memcpy(part, rest, part_length);
        part[part_length] = '\0';
        int fd = openat(at, part, SEARCH_OPEN_FLAGS);
        int saved = errno;
        if (at != AT_FDCWD) close(at);
        if (fd < 0) {
            errno = saved;
            return -1;
        }
        at = fd;
        rest = cut + 1;
    }
    int fd = openat(at, rest, SEARCH_OPEN_FLAGS);
    int saved = errno;
    if (at != AT_FDCWD) close(at);
    errno = saved;
    return fd;
}

/* A folder that is gone, or no longer a folder, since it was listed is nothing the search
   couldn't read. */
static int search_is_gone(int errnum) { return errnum == ENOENT || errnum == ENOTDIR || errnum == ELOOP; }

/* ── Listing a folder ────────────────────────────────────────────── */

typedef struct {
    ft_search *search;
    int index;       /* which worker, for the match callback */
    char *path;      /* the item's whole path, built in place */
    size_t capacity; /* of `path` */
} search_worker;

/* `path` holds at least `length` bytes and a NUL. */
static int search_reserve(search_worker *worker, size_t length) {
    if (length + 1 <= worker->capacity) return 1;
    size_t capacity = worker->capacity * 2;
    while (capacity < length + 1) capacity *= 2;
    char *grown = realloc(worker->path, capacity);
    if (!grown) return 0;
    worker->path = grown;
    worker->capacity = capacity;
    return 1;
}

/* Lists the folder open as `fd` (closed here), at `folder` (`folder_length` bytes): each file and
   folder passed goes to the callbacks, and each folder to the stack when the walk goes deeper. */
static void search_list(search_worker *worker, int fd, const char *folder, size_t folder_length, int is_root) {
    ft_search *search = worker->search;
    const ft_search_options *options = &search->options;
    DIR *listing = fdopendir(fd);
    if (!listing) {
        int errnum = errno;
        close(fd);
        if (is_root) {
            atomic_store(&search->root_errno, errnum);
        } else if (!search_is_gone(errnum)) {
            atomic_store(&search->unreadable, 1);
        }
        return;
    }
    /* The folder's path, then a slash unless it is "/". */
    size_t prefix = folder_length;
    if (!search_reserve(worker, folder_length + 1)) {
        closedir(listing);
        search_fail(search);
        return;
    }
    memcpy(worker->path, folder, folder_length);
    if (folder_length == 0 || folder[folder_length - 1] != '/') worker->path[prefix++] = '/';

    char held[FT_HELD_NAME_SIZE];
    int listed = 0;
    for (;;) {
        if (search_should_stop(search)) break;
        errno = 0;
        struct dirent *entry = readdir(listing);
        if (!entry) {
            int errnum = errno;
            if (errnum != 0) {
                if (is_root && !listed) {
                    atomic_store(&search->root_errno, errnum);
                } else if (!search_is_gone(errnum)) {
                    atomic_store(&search->unreadable, 1);
                }
            }
            break;
        }
        listed = 1;
        const char *name = entry->d_name;
        size_t name_length = entry->d_namlen;
        if (name_length == 0 || (name_length == 1 && name[0] == '.') ||
            (name_length == 2 && name[0] == '.' && name[1] == '.')) {
            continue;
        }
        int type = entry->d_type;
        if (type == DT_UNKNOWN) {
            /* A disk that doesn't keep types in its folders: the item is asked. */
            struct stat info;
            if (fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0) continue;
            type = S_ISDIR(info.st_mode) ? DT_DIR : S_ISREG(info.st_mode) ? DT_REG : DT_LNK;
        }
        /* Files and folders only: no link is listed or followed. */
        if (type != DT_REG && type != DT_DIR) continue;
        int is_folder = type == DT_DIR;
        int dotted = name[0] == '.';
        if (dotted && !options->include_hidden) continue;
        if (options->skip_git && name_length == 4 && memcmp(name, ".git", 4) == 0) continue;

        /* The name the disk holds for the item, which is how the rest of the app names it. */
        const char *listed_name = name;
        if (search->respells && ft_name_has_accent_bytes(name, name_length) &&
            ft_held_name_on(fd, search->root_dev, name, held, sizeof(held)) == 0) {
            name = held;
            name_length = strlen(held);
        }
        size_t length = prefix + name_length;
        if (!search_reserve(worker, length)) {
            search_fail(search);
            break;
        }
        memcpy(worker->path + prefix, name, name_length);
        worker->path[length] = '\0';

        if (options->skip_system_volumes && is_folder &&
            (strcmp(worker->path, "/Volumes") == 0 || strcmp(worker->path, "/System/Volumes") == 0)) {
            continue;
        }
        int matched = search->match(search->context, worker->index, worker->path, length, prefix, is_folder);
        if (matched == FT_SEARCH_STOP) {
            search_stop(search);
            break;
        }
        if (matched == FT_SEARCH_MATCH) {
            /* Hidden by its flag, read now it is wanted. */
            int is_hidden = dotted;
            struct stat info;
            if (!is_hidden && fstatat(fd, listed_name, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
                (info.st_flags & UF_HIDDEN) != 0) {
                is_hidden = 1;
            }
            if (!is_hidden || options->include_hidden) {
                if (search->keep(search->context, worker->path, length, prefix, is_folder, is_hidden) != 0) {
                    search_stop(search);
                    break;
                }
            } else if (is_folder) {
                /* A hidden folder's items are hidden too. */
                continue;
            }
        }
        if (is_folder && options->recursive) {
            char *child = malloc(length + 1);
            if (child) memcpy(child, worker->path, length + 1);
            if (!child || !search_push(search, child, length)) {
                search_fail(search);
                break;
            }
        }
    }
    closedir(listing);
}

static void *search_worker_main(void *argument) {
    search_worker *worker = argument;
    ft_search *search = worker->search;
    search_node *node;
    while ((node = search_pop(search)) != NULL) {
        int fd = search_open_path(node->path);
        if (fd < 0) {
            if (!search_is_gone(errno)) atomic_store(&search->unreadable, 1);
        } else {
            struct stat info;
            /* A folder with the flag that hides it, and all inside it, are left out unless asked for. */
            if (!search->options.include_hidden && fstat(fd, &info) == 0 && (info.st_flags & UF_HIDDEN) != 0) {
                close(fd);
            } else {
                search_list(worker, fd, node->path, node->length, 0);
            }
        }
        free(node->path);
        free(node);
        search_done_with_folder(search);
    }
    return NULL;
}

/* ── A search ────────────────────────────────────────────────────── */

int ft_search_default_threads(void) { return SEARCH_DEFAULT_THREADS; }

ft_search *ft_search_create(const char *root_path, ft_search_options options, ft_search_match match,
                            ft_search_keep keep, void *context) {
    ft_search *search = calloc(1, sizeof(ft_search));
    if (!search) return NULL;
    search->root_path = strdup(root_path);
    if (!search->root_path) {
        free(search);
        return NULL;
    }
    search->options = options;
    search->match = match;
    search->keep = keep;
    search->context = context;
    pthread_mutex_init(&search->lock, NULL);
    pthread_cond_init(&search->cond, NULL);
    atomic_init(&search->stopped, 0);
    atomic_init(&search->failed, 0);
    atomic_init(&search->unreadable, 0);
    atomic_init(&search->root_errno, 0);
    return search;
}

void ft_search_cancel(ft_search *search) { search_stop(search); }

ft_search_result ft_search_run(ft_search *search) {
    ft_search_result result;
    memset(&result, 0, sizeof(result));
    if (search->run) {
        result.errnum = EALREADY;
        return result;
    }
    search->run = 1;

    /* The folder searched may be reached through a link, as /tmp is. */
    int root_fd = open(search->root_path, O_RDONLY | O_DIRECTORY);
    if (root_fd < 0) {
        result.errnum = errno;
        result.stopped = atomic_load(&search->stopped);
        return result;
    }
    struct stat root_stat;
    if (fstat(root_fd, &root_stat) != 0) {
        result.errnum = errno;
        close(root_fd);
        return result;
    }
    search->root_dev = root_stat.st_dev;
    search->respells = ft_listing_respells_names(root_fd);

    int wanted = search->options.threads > 0 ? search->options.threads : SEARCH_DEFAULT_THREADS;
    if (wanted > SEARCH_MAX_THREADS) wanted = SEARCH_MAX_THREADS;
    search_worker workers[SEARCH_MAX_THREADS];
    int prepared = 0;
    for (int index = 0; index < wanted; index++) {
        workers[index].search = search;
        workers[index].index = index;
        workers[index].capacity = 1024;
        workers[index].path = malloc(workers[index].capacity);
        if (!workers[index].path) break;
        prepared++;
    }
    if (prepared == 0) {
        close(root_fd);
        result.errnum = ENOMEM;
        return result;
    }

    /* The folder searched is listed first, on this thread, so a folder that can't be listed at all is told
       apart from one inside it. */
    pthread_mutex_lock(&search->lock);
    search->active = 1;
    pthread_mutex_unlock(&search->lock);
    search_list(&workers[0], root_fd, search->root_path, strlen(search->root_path), 1);

    pthread_t threads[SEARCH_MAX_THREADS];
    int created = 0;
    if (!atomic_load(&search->root_errno)) {
        int qos = search->options.qos_class != 0 ? search->options.qos_class : QOS_CLASS_USER_INITIATED;
        for (int index = 1; index < prepared; index++) {
            pthread_attr_t attributes;
            pthread_attr_init(&attributes);
            pthread_attr_set_qos_class_np(&attributes, (qos_class_t)qos, 0);
            int made = pthread_create(&threads[created], &attributes, search_worker_main, &workers[index]);
            pthread_attr_destroy(&attributes);
            if (made != 0) break;
            created++;
        }
    }
    search_done_with_folder(search);
    /* This thread works too. */
    if (!atomic_load(&search->root_errno)) search_worker_main(&workers[0]);
    for (int index = 0; index < created; index++) pthread_join(threads[index], NULL);

    /* What was left on the stack once the walk stopped. */
    search_node *node = search->head;
    while (node) {
        search_node *next = node->next;
        free(node->path);
        free(node);
        node = next;
    }
    search->head = NULL;
    for (int index = 0; index < prepared; index++) free(workers[index].path);

    result.errnum = atomic_load(&search->failed) ? ENOMEM : atomic_load(&search->root_errno);
    result.unreadable_folders = atomic_load(&search->unreadable);
    result.stopped = atomic_load(&search->stopped);
    return result;
}

void ft_search_destroy(ft_search *search) {
    if (!search) return;
    pthread_mutex_destroy(&search->lock);
    pthread_cond_destroy(&search->cond);
    free(search->root_path);
    free(search);
}
