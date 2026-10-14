// Interface to foldersize.c, the folder size walker (a port of packages/native-fs/src/native_foldersize.c).
#ifndef FT_FOLDERSIZE_H
#define FT_FOLDERSIZE_H

#include <stdint.h>

/// What a folder holds, at any depth.
typedef struct {
    int64_t size_bytes;
    int64_t disk_bytes;
    int64_t file_count;
    int64_t folder_count;
} ft_folder_stats;

/// A folder the walk has finished, with the totals of everything in it. Lists are in the order the
/// folders were finished: a folder comes after the folders inside it.
typedef struct ft_finished_folder {
    char *path;
    ft_folder_stats stats;
    struct ft_finished_folder *next;
} ft_finished_folder;

typedef struct ft_folder_walk ft_folder_walk;

/// Called from a worker thread when the finished list goes from empty to not empty (so once per
/// batch the consumer has not taken yet). It must not call back into the walk except to take.
typedef void (*ft_folder_walk_notify)(void *context);

/// How a walk ended: valid once `ft_folder_walk_run` has returned.
typedef struct {
    int64_t size_bytes;
    int64_t disk_bytes;
    int64_t file_count;
    int64_t folder_count;
    /// The disk walked: the walk never leaves it.
    int64_t dev;
    /// 0, or the errno the walk failed with (the first read error for an incomplete root).
    int errnum;
    /// Set when `ft_folder_walk_cancel` was called before the walk ended.
    int cancelled;
} ft_folder_walk_result;

/// A walk of `root_path`, not started. `background` walks at utility QoS. NULL when out of memory.
ft_folder_walk *ft_folder_walk_create(
    const char *root_path, int background, ft_folder_walk_notify notify, void *context);

/// Walks to the end with four worker threads, blocking until they are done.
void ft_folder_walk_run(ft_folder_walk *walk);

/// Stops the walk: every worker checks before each listing. Safe from any thread, before or during the run.
void ft_folder_walk_cancel(ft_folder_walk *walk);

/// The folders finished since the last take, oldest first, or NULL. Free with `ft_finished_folders_free`.
ft_finished_folder *ft_folder_walk_take_finished(ft_folder_walk *walk);

void ft_finished_folders_free(ft_finished_folder *head);

/// The disk walked. Set before any folder is finished, so it is safe to read once told of one.
int64_t ft_folder_walk_dev(const ft_folder_walk *walk);

ft_folder_walk_result ft_folder_walk_get_result(const ft_folder_walk *walk);

/// Frees the walk and what it still holds. Not while it runs.
void ft_folder_walk_destroy(ft_folder_walk *walk);

typedef enum { FT_ITEM_OTHER = 0, FT_ITEM_FILE = 1, FT_ITEM_FOLDER = 2 } ft_item_kind;

typedef struct {
    ft_item_kind kind;
    int64_t size_bytes;
    int64_t disk_bytes;
    int64_t dev;
} ft_item_size;

/// One item as the walk counts it inside its folder (nativeItemSize). Returns 0, or the errno.
int ft_item_size_of(const char *path, ft_item_size *out);

/// The name of an errno as Node spells it ("ENOENT"), "UNKNOWN" for one not listed.
const char *ft_errno_code(int errnum);

#endif
