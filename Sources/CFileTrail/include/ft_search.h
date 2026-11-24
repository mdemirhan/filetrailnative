// Interface to search.c, the walk a search runs on.
#ifndef FT_SEARCH_H
#define FT_SEARCH_H

#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>

/// What a search walks and leaves out.
typedef struct {
    /// Into the folders inside the folder searched, at any depth; otherwise its own items only.
    int recursive;
    /// Items whose name starts with a dot or that have the flag that hides one, and what is inside such folders.
    int include_hidden;
    /// Items named `.git`, and what is inside them.
    int skip_git;
    /// The search is of "/": /Volumes and /System/Volumes are left out, as other disks are searched from their own top
    /// and the data volume is reached through the firmlinks.
    int skip_system_volumes;
    /// Worker threads; 0 for the default.
    int threads;
    /// The threads' quality of service, a `qos_class_t`; 0 for user-initiated.
    int qos_class;
    /// Symbolic links are listed too (never followed), for a search that asks for them.
    int include_links;
    /// Each item kept is read (`fstatat`, from its folder) and the read passed to `ft_search_keep`, for conditions
    /// that need what it holds. Otherwise an item is read only for the flag that hides it, when its name doesn't.
    int wants_stat;
} ft_search_options;

/// What `ft_search_match` answers of an item.
#define FT_SEARCH_NO_MATCH 0
#define FT_SEARCH_MATCH 1
/// Ends the walk.
#define FT_SEARCH_STOP 2
/// A folder the search leaves out: it is no match, and what is in it isn't walked.
#define FT_SEARCH_SKIP 3

/// Called on a worker thread for each file and folder the walk passes, with its whole path (NUL-terminated, `length`
/// bytes without the NUL), where its name starts in it, and whether it is a folder or a symbolic link: whether it is
/// what the search looks for by what its folder lists of it (`FT_SEARCH_…`). Many threads call it at once, each with
/// its own `worker`, from 0 up to the number of threads.
typedef int (*ft_search_match)(void *context, int worker, const char *path, size_t length, size_t name_offset,
                               int is_folder, int is_link);

/// Called on a worker thread for each item matched that the walk keeps, with whether it is hidden (a name starting
/// with a dot, or the flag that hides one), whether it is a symbolic link, and what reading it gave (NULL when it
/// wasn't read, or couldn't be). `folder` is its folder, open, for the length of the call: an item whose path is too
/// long for a call by path is reached from it. Returns 0 to go on, 1 to end the walk.
typedef int (*ft_search_keep)(void *context, int worker, const char *path, size_t length, size_t name_offset,
                              int is_folder, int is_hidden, int is_link, const struct stat *info, int folder);

/// How a walk ended: valid once `ft_search_run` has returned.
typedef struct {
    /// Why the folder searched couldn't be listed at all (0 when it was).
    int errnum;
    /// A folder inside couldn't be read, for a reason other than being gone: what is in it isn't searched.
    int unreadable_folders;
    /// The walk was ended early: `ft_search_cancel`, or a callback asked for it.
    int stopped;
} ft_search_result;

typedef struct ft_search ft_search;

/// A walk of `root_path`, not started. NULL when out of memory.
ft_search *ft_search_create(const char *root_path, ft_search_options options, ft_search_match match,
                            ft_search_keep keep, void *context);

/// Walks to the end, on the calling thread and the walk's workers, and returns how it ended. Once only.
ft_search_result ft_search_run(ft_search *search);

/// Ends the walk as soon as each worker next looks: safe from any thread, at any time before `ft_search_destroy`.
void ft_search_cancel(ft_search *search);

void ft_search_destroy(ft_search *search);

/// The number of threads a walk uses when its options give 0.
int ft_search_default_threads(void);

#endif
