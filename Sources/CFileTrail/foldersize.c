// Port of packages/native-fs/src/native_foldersize.c, without N-API: Swift drives the walk.
//
// Recursive folder size calculation with macOS getattrlistbulk(2) on 4 worker threads.
// getattrlistbulk returns metadata for all entries in a directory in one syscall (avoiding per-file
// stat), and parallelism lets independent subtrees be walked concurrently.
//
// Tracks four metrics per directory:
//   - logical size (ATTR_FILE_DATALENGTH)
//   - allocated disk bytes (ATTR_FILE_ALLOCSIZE)
//   - file count (regular files + symlinks)
//   - folder count (subfolders at any depth, packages included; a package's contents count too, as
//     they are walked like any folder)
//
// The walk stays on the disk it starts on, and doesn't go into a folder another volume is mounted on.
// On the startup disk, /Users, /Applications and the like are firmlinks to the same folders under
// /System/Volumes/Data, where the data volume is mounted: measuring / goes through the firmlinks and
// leaves out /System/Volumes/Data, so each folder is counted once, under the path it is browsed at.
//
// A folder whose listing fails part way (EIO, say), or that holds a sub-folder that couldn't be opened
// for a reason other than having no access to it, is incomplete: it and the folders holding it are
// never reported finished, and a walk whose root is incomplete fails with the error. A sub-folder the
// walk has no access to is counted as a folder with nothing in it, as Finder does.
//
// Each folder is finished as soon as everything inside it has been walked: it counts its own listing
// and each sub-folder not finished yet, and whichever thread brings that count to zero adds the
// folder's totals into its parent's and puts the folder on the finished list. The consumer takes from
// that list while the walk runs (it is told when the list stops being empty); whatever is left on it
// when the walk ends is taken after.

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

#include "ft_foldersize.h"

#define BULK_BUF_SIZE (256 * 1024)
#define NUM_THREADS 4

typedef ft_folder_stats dir_stats_t;
typedef ft_finished_folder dir_entry_t;

/* ── Finished directories ────────────────────────────────────────── */

/* Folders finished and not yet handed over: workers add, the consumer takes. */
typedef struct {
  pthread_mutex_t lock;
  dir_entry_t *head;
  ft_folder_walk_notify notify;
  void *notify_context;
} finished_list_t;

/* Takes ownership of `path`. Returns 1 on success, 0 on allocation failure. */
static int finished_push(finished_list_t *list, char *path, dir_stats_t stats) {
  dir_entry_t *entry = malloc(sizeof(dir_entry_t));
  if (!entry) return 0;
  entry->path = path;
  entry->stats = stats;
  pthread_mutex_lock(&list->lock);
  int was_empty = list->head == NULL;
  entry->next = list->head;
  list->head = entry;
  pthread_mutex_unlock(&list->lock);
  if (was_empty && list->notify) list->notify(list->notify_context);
  return 1;
}

/* Everything on the list, oldest first, which is left empty; the caller frees it. */
static dir_entry_t *finished_take(finished_list_t *list) {
  pthread_mutex_lock(&list->lock);
  dir_entry_t *head = list->head;
  list->head = NULL;
  pthread_mutex_unlock(&list->lock);
  dir_entry_t *oldest_first = NULL;
  while (head) {
    dir_entry_t *next = head->next;
    head->next = oldest_first;
    oldest_first = head;
    head = next;
  }
  return oldest_first;
}

void ft_finished_folders_free(ft_finished_folder *head) {
  while (head) {
    dir_entry_t *next = head->next;
    free(head->path);
    free(head);
    head = next;
  }
}

/* ── A folder being walked ───────────────────────────────────────── */

typedef struct walk_dir {
  char *path;              /* owned until the folder is finished, then the finished list's */
  struct walk_dir *parent; /* NULL for the root */
  /* Its own listing, plus each sub-folder not finished yet: zero once all is counted. */
  atomic_int pending;
  /* Set when part of it couldn't be read: its totals leave something out. */
  atomic_int incomplete;
  /* Its own files and folders, plus the totals of each finished sub-folder. */
  _Atomic int64_t size_bytes;
  _Atomic int64_t disk_bytes;
  _Atomic int64_t file_count;
  _Atomic int64_t folder_count;
  /* The list of folders the creating thread made, all freed when the walk ends: one
     that never finishes (the walk stopped) has no one else to free it. */
  struct walk_dir *next_allocated;
} walk_dir_t;

/* Takes ownership of `path` (freed here on failure). NULL on allocation failure. */
static walk_dir_t *walk_dir_new(char *path, walk_dir_t *parent) {
  walk_dir_t *dir = malloc(sizeof(walk_dir_t));
  if (!dir) {
    free(path);
    return NULL;
  }
  dir->path = path;
  dir->parent = parent;
  atomic_init(&dir->pending, 1);
  atomic_init(&dir->incomplete, 0);
  atomic_init(&dir->size_bytes, 0);
  atomic_init(&dir->disk_bytes, 0);
  atomic_init(&dir->file_count, 0);
  atomic_init(&dir->folder_count, 0);
  dir->next_allocated = NULL;
  return dir;
}

static void walk_dirs_free(walk_dir_t *head) {
  while (head) {
    walk_dir_t *next = head->next_allocated;
    free(head->path);
    free(head);
    head = next;
  }
}

/* ── Concurrent work queue ───────────────────────────────────────── */

typedef struct dir_node {
  int fd;
  walk_dir_t *dir; /* not owned: freed with its thread's allocations */
  struct dir_node *next;
} dir_node_t;

typedef struct {
  dir_node_t *head;
  pthread_mutex_t lock;
  atomic_int active; /* threads currently processing a directory */
  pthread_cond_t cond;
  int finished;
  dev_t root_dev;
  atomic_int *cancelled;
  atomic_int failed;     /* set on allocation failure; walk aborts with ENOMEM */
  atomic_int read_errno; /* the first error that left a folder incomplete */
} work_queue_t;

static void wq_init(work_queue_t *wq, dev_t dev, atomic_int *cancelled) {
  wq->head = NULL;
  pthread_mutex_init(&wq->lock, NULL);
  atomic_store(&wq->active, 0);
  pthread_cond_init(&wq->cond, NULL);
  wq->finished = 0;
  wq->root_dev = dev;
  wq->cancelled = cancelled;
  atomic_store(&wq->failed, 0);
  atomic_store(&wq->read_errno, 0);
}

/* `dir` leaves out part of what is in it, which couldn't be read for `errnum`. */
static void mark_incomplete(work_queue_t *wq, walk_dir_t *dir, int errnum) {
  int none = 0;
  atomic_compare_exchange_strong(&wq->read_errno, &none, errnum != 0 ? errnum : EIO);
  atomic_store(&dir->incomplete, 1);
}

/* Whether a sub-folder that couldn't be opened for `errnum` is simply left out, as one
   the walk has no access to, or one gone or replaced since it was listed; anything else
   (no file descriptors left, an I/O error) leaves its folder incomplete. */
static int is_skippable_open_error(int errnum) {
  return errnum == EACCES || errnum == EPERM || errnum == ENOENT || errnum == ENOTDIR ||
         errnum == ELOOP;
}

/* Abort the walk: all workers stop at the next cancelled/failed check. */
static void wq_fail(work_queue_t *wq) {
  atomic_store(&wq->failed, 1);
  pthread_mutex_lock(&wq->lock);
  pthread_cond_broadcast(&wq->cond);
  pthread_mutex_unlock(&wq->lock);
}

/* Whether the walk was cancelled or failed: what it has counted since may be partial. */
static int wq_stopped(work_queue_t *wq) {
  return atomic_load(wq->cancelled) || atomic_load(&wq->failed);
}

/* Returns 1 on success (queue owns fd), 0 on allocation failure. */
static int wq_push(work_queue_t *wq, int fd, walk_dir_t *dir) {
  dir_node_t *node = malloc(sizeof(dir_node_t));
  if (!node) return 0;
  node->fd = fd;
  node->dir = dir;
  pthread_mutex_lock(&wq->lock);
  node->next = wq->head;
  wq->head = node;
  pthread_cond_signal(&wq->cond);
  pthread_mutex_unlock(&wq->lock);
  return 1;
}

/* Returns 1 and fills fd_out/dir_out on success, 0 when all work is done. */
static int wq_pop(work_queue_t *wq, int *fd_out, walk_dir_t **dir_out) {
  pthread_mutex_lock(&wq->lock);
  for (;;) {
    if (wq_stopped(wq) || wq->finished) {
      pthread_mutex_unlock(&wq->lock);
      return 0;
    }
    if (wq->head) {
      dir_node_t *node = wq->head;
      wq->head = node->next;
      *fd_out = node->fd;
      *dir_out = node->dir;
      free(node);
      atomic_fetch_add(&wq->active, 1);
      pthread_mutex_unlock(&wq->lock);
      return 1;
    }
    if (atomic_load(&wq->active) == 0) {
      wq->finished = 1;
      pthread_cond_broadcast(&wq->cond);
      pthread_mutex_unlock(&wq->lock);
      return 0;
    }
    pthread_cond_wait(&wq->cond, &wq->lock);
  }
}

static void wq_done(work_queue_t *wq) {
  if (atomic_fetch_sub(&wq->active, 1) == 1) {
    pthread_mutex_lock(&wq->lock);
    pthread_cond_broadcast(&wq->cond);
    pthread_mutex_unlock(&wq->lock);
  }
}

static void wq_destroy(work_queue_t *wq) {
  dir_node_t *n = wq->head;
  while (n) {
    dir_node_t *next = n->next;
    close(n->fd);
    free(n);
    n = next;
  }
  pthread_mutex_destroy(&wq->lock);
  pthread_cond_destroy(&wq->cond);
}

/* ── Shared attrlist (read-only, safe across threads) ────────────── */

static struct attrlist g_attrlist;
static pthread_once_t g_attrlist_once = PTHREAD_ONCE_INIT;

static void init_attrlist(void) {
  memset(&g_attrlist, 0, sizeof(g_attrlist));
  g_attrlist.bitmapcount = ATTR_BIT_MAP_COUNT;
  /* Attributes returned in bitmap bit order (lowest first):
     ATTR_CMN_NAME (bit 0), then ATTR_CMN_OBJTYPE (bit 3). */
  g_attrlist.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE;
  /* Folders only, after the common attributes: whether one is mounted on. */
  g_attrlist.dirattr = ATTR_DIR_MOUNTSTATUS;
  /* File attrs in bit order: ATTR_FILE_ALLOCSIZE (bit 2, 0x04)
     then ATTR_FILE_DATALENGTH (bit 9, 0x200). */
  g_attrlist.fileattr = ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH;
}

/* ── Worker thread state ─────────────────────────────────────────── */

typedef struct {
  work_queue_t *wq;
  finished_list_t *finished;
  int64_t total_bytes;
  int64_t total_disk_bytes;
  int64_t total_file_count;
  int64_t total_folder_count;
  walk_dir_t *allocated; /* the folders this thread made */
} thread_arg_t;

/* ── Process one directory with getattrlistbulk ──────────────────── */

typedef struct {
  int64_t direct_bytes;
  int64_t direct_disk_bytes;
  int64_t direct_file_count;
  int64_t direct_folder_count;
} process_dir_result_t;

/* Lists `dir` and queues its sub-folders on the same disk, those another volume is mounted
   on left out; adds what is directly in it to its totals. */
static process_dir_result_t process_dir(int dirfd, walk_dir_t *dir, thread_arg_t *ta,
                                        char *buf) {
  work_queue_t *wq = ta->wq;
  const char *dir_path = dir->path;
  int64_t direct_bytes = 0;
  int64_t direct_disk_bytes = 0;
  int64_t direct_file_count = 0;
  int64_t direct_folder_count = 0;

  for (;;) {
    if (wq_stopped(wq)) break;

    int count = getattrlistbulk(dirfd, &g_attrlist, buf, BULK_BUF_SIZE, 0);
    if (count < 0) {
      /* The rest of the listing can't be read: what it holds is only partly counted. */
      mark_incomplete(wq, dir, errno);
      break;
    }
    if (count == 0) break;

    char *ptr = buf;
    for (int i = 0; i < count; i++) {
      uint32_t entry_len;
      memcpy(&entry_len, ptr, sizeof(entry_len));
      char *p = ptr + sizeof(uint32_t);

      /* attribute_set_t (20 bytes, always first) */
      attribute_set_t returned;
      memcpy(&returned, p, sizeof(returned));
      p += sizeof(returned);

      /* ATTR_CMN_NAME (bit 0) -- attrreference_t (8 bytes) */
      const char *name = NULL;
      char *name_ref_start = p;
      if (returned.commonattr & ATTR_CMN_NAME) {
        attrreference_t name_ref;
        memcpy(&name_ref, p, sizeof(name_ref));
        name = name_ref_start + name_ref.attr_dataoffset;
        p += sizeof(name_ref);
      }

      /* ATTR_CMN_OBJTYPE (bit 3) -- uint32_t */
      uint32_t obj_type = 0;
      if (returned.commonattr & ATTR_CMN_OBJTYPE) {
        memcpy(&obj_type, p, sizeof(obj_type));
        p += sizeof(obj_type);
      }

      /* ATTR_DIR_MOUNTSTATUS -- uint32_t, folders only */
      uint32_t mount_status = 0;
      if (returned.dirattr & ATTR_DIR_MOUNTSTATUS) {
        memcpy(&mount_status, p, sizeof(mount_status));
        p += sizeof(mount_status);
      }

      /* File attrs in bit order: ALLOCSIZE (bit 2) then DATALENGTH (bit 9) */
      int64_t alloc_size = 0;
      if (returned.fileattr & ATTR_FILE_ALLOCSIZE) {
        memcpy(&alloc_size, p, sizeof(alloc_size));
        p += sizeof(alloc_size);
      }

      int64_t data_size = 0;
      if (returned.fileattr & ATTR_FILE_DATALENGTH) {
        memcpy(&data_size, p, sizeof(data_size));
        p += sizeof(data_size);
      }

      /* Skip . and .. */
      if (name && name[0] == '.' &&
          (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
        ptr += entry_len;
        continue;
      }

      if (obj_type == VREG || obj_type == VLNK) {
        direct_bytes += data_size;
        direct_disk_bytes += alloc_size;
        direct_file_count++;
      } else if (obj_type == VDIR && name) {
        /* Counted even when it isn't walked (another volume, no access). */
        direct_folder_count++;
        /* A volume mounted on it is left out, even one of the startup disk's group, which
           has the same device: /System/Volumes/Data is reached through the firmlinks. */
        int mounted_on = (mount_status & DIR_MNTSTATUS_MNTPOINT) != 0;
        int subfd =
            mounted_on ? -1 : openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (subfd < 0 && !mounted_on && !is_skippable_open_error(errno)) {
          mark_incomplete(wq, dir, errno);
        }
        if (subfd >= 0) {
          struct stat sub_stat;
          if (fstat(subfd, &sub_stat) == 0 && sub_stat.st_dev == wq->root_dev) {
            /* Build child path: dir_path + "/" + name, with no second "/" after "/". */
            size_t dir_len = strlen(dir_path);
            size_t sep_len = dir_len > 0 && dir_path[dir_len - 1] == '/' ? 0 : 1;
            size_t name_len = strlen(name);
            char *child_path = malloc(dir_len + sep_len + name_len + 1);
            walk_dir_t *child = NULL;
            if (child_path) {
              memcpy(child_path, dir_path, dir_len);
              if (sep_len) child_path[dir_len] = '/';
              memcpy(child_path + dir_len + sep_len, name, name_len + 1);
              child = walk_dir_new(child_path, dir);
            }
            if (!child) {
              close(subfd);
              wq_fail(wq);
            } else {
              child->next_allocated = ta->allocated;
              ta->allocated = child;
              /* Counted before it is queued, so it can't finish before it is waited for. */
              atomic_fetch_add(&dir->pending, 1);
              if (!wq_push(wq, subfd, child)) {
                close(subfd);
                wq_fail(wq);
              }
            }
          } else {
            close(subfd);
          }
        }
      }

      ptr += entry_len;
    }
  }

  close(dirfd);
  atomic_fetch_add(&dir->size_bytes, direct_bytes);
  atomic_fetch_add(&dir->disk_bytes, direct_disk_bytes);
  atomic_fetch_add(&dir->file_count, direct_file_count);
  atomic_fetch_add(&dir->folder_count, direct_folder_count);

  process_dir_result_t result;
  result.direct_bytes = direct_bytes;
  result.direct_disk_bytes = direct_disk_bytes;
  result.direct_file_count = direct_file_count;
  result.direct_folder_count = direct_folder_count;
  return result;
}

/* Marks one part of `dir` done: its own listing, or a sub-folder. The part that finishes
   the folder puts it on the finished list and adds its totals into its parent's, which
   is one part of the parent done in turn. Once the walk has stopped nothing more is
   finished, as a listing cut short may have counted only part of a folder. An incomplete
   folder isn't finished either, and leaves its parent incomplete. */
static void finish_part(thread_arg_t *ta, walk_dir_t *dir) {
  while (atomic_fetch_sub(&dir->pending, 1) == 1) {
    walk_dir_t *parent = dir->parent;
    /* The root's totals are the result. */
    if (!parent || wq_stopped(ta->wq)) {
      return;
    }
    if (atomic_load(&dir->incomplete)) {
      atomic_store(&parent->incomplete, 1);
      dir = parent;
      continue;
    }
    dir_stats_t stats;
    stats.size_bytes = atomic_load(&dir->size_bytes);
    stats.disk_bytes = atomic_load(&dir->disk_bytes);
    stats.file_count = atomic_load(&dir->file_count);
    stats.folder_count = atomic_load(&dir->folder_count);
    if (!finished_push(ta->finished, dir->path, stats)) {
      wq_fail(ta->wq);
      return;
    }
    dir->path = NULL;
    atomic_fetch_add(&parent->size_bytes, stats.size_bytes);
    atomic_fetch_add(&parent->disk_bytes, stats.disk_bytes);
    atomic_fetch_add(&parent->file_count, stats.file_count);
    atomic_fetch_add(&parent->folder_count, stats.folder_count);
    dir = parent;
  }
}

/* ── Worker thread ───────────────────────────────────────────────── */

static void *worker_fn(void *arg) {
  thread_arg_t *ta = (thread_arg_t *)arg;
  char *buf = malloc(BULK_BUF_SIZE);
  if (!buf) {
    /* Never popped anything, so queue accounting is untouched; flag the
       failure so the whole walk aborts with ENOMEM instead of silently
       running with fewer workers. */
    wq_fail(ta->wq);
    return NULL;
  }

  int fd;
  walk_dir_t *dir;
  while (wq_pop(ta->wq, &fd, &dir)) {
    process_dir_result_t r = process_dir(fd, dir, ta, buf);
    ta->total_bytes += r.direct_bytes;
    ta->total_disk_bytes += r.direct_disk_bytes;
    ta->total_file_count += r.direct_file_count;
    ta->total_folder_count += r.direct_folder_count;
    finish_part(ta, dir);
    wq_done(ta->wq);
  }

  free(buf);
  return NULL;
}

/* ── A walk ──────────────────────────────────────────────────────── */

struct ft_folder_walk {
  char *root_path;
  int background;       /* walked at utility QoS: a measurement the app started itself */
  atomic_int cancelled; /* written from any thread, read by worker pthreads */
  ft_folder_walk_result result;
  finished_list_t finished;
};

ft_folder_walk *ft_folder_walk_create(const char *root_path, int background,
                                      ft_folder_walk_notify notify, void *context) {
  ft_folder_walk *w = (ft_folder_walk *)calloc(1, sizeof(ft_folder_walk));
  if (!w) return NULL;
  w->root_path = strdup(root_path);
  if (!w->root_path) {
    free(w);
    return NULL;
  }
  w->background = background ? 1 : 0;
  atomic_init(&w->cancelled, 0);
  pthread_mutex_init(&w->finished.lock, NULL);
  w->finished.head = NULL;
  w->finished.notify = notify;
  w->finished.notify_context = context;
  return w;
}

void ft_folder_walk_cancel(ft_folder_walk *walk) {
  atomic_store(&walk->cancelled, 1);
}

ft_finished_folder *ft_folder_walk_take_finished(ft_folder_walk *walk) {
  return finished_take(&walk->finished);
}

ft_folder_walk_result ft_folder_walk_get_result(const ft_folder_walk *walk) {
  return walk->result;
}

void ft_folder_walk_destroy(ft_folder_walk *walk) {
  if (!walk) return;
  ft_finished_folders_free(finished_take(&walk->finished));
  pthread_mutex_destroy(&walk->finished.lock);
  free(walk->root_path);
  free(walk);
}

void ft_folder_walk_run(ft_folder_walk *w) {
  pthread_once(&g_attrlist_once, init_attrlist);
  ft_folder_walk_result *result = &w->result;
  memset(result, 0, sizeof(*result));

  int root_fd = open(w->root_path, O_RDONLY | O_DIRECTORY);
  if (root_fd < 0) {
    result->errnum = errno;
    result->cancelled = atomic_load(&w->cancelled);
    return;
  }

  struct stat root_stat;
  if (fstat(root_fd, &root_stat) != 0) {
    result->errnum = errno;
    result->cancelled = atomic_load(&w->cancelled);
    close(root_fd);
    return;
  }

  /* Set before any worker starts, so a folder on the finished list was put there after it was set. */
  result->dev = (int64_t)root_stat.st_dev;
  char *root_path = strdup(w->root_path);
  walk_dir_t *root = root_path ? walk_dir_new(root_path, NULL) : NULL;
  if (!root) {
    result->errnum = ENOMEM;
    result->cancelled = atomic_load(&w->cancelled);
    close(root_fd);
    return;
  }
  work_queue_t wq;
  wq_init(&wq, root_stat.st_dev, &w->cancelled);
  if (!wq_push(&wq, root_fd, root)) {
    result->errnum = ENOMEM;
    result->cancelled = atomic_load(&w->cancelled);
    close(root_fd);
    wq_destroy(&wq);
    walk_dirs_free(root);
    return;
  }

  /* Spawn worker threads. The walk goes on with those that could be made; with none, it
     fails. */
  thread_arg_t args[NUM_THREADS];
  pthread_t threads[NUM_THREADS];
  int created = 0;
  int create_error = 0;
  for (int i = 0; i < NUM_THREADS; i++) {
    args[i].wq = &wq;
    args[i].finished = &w->finished;
    args[i].total_bytes = 0;
    args[i].total_disk_bytes = 0;
    args[i].total_file_count = 0;
    args[i].total_folder_count = 0;
    args[i].allocated = NULL;
  }
  for (int i = 0; i < NUM_THREADS; i++) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    /* A walk nobody asked for gives way to the rest of the Mac, as Spotlight's does. */
    if (w->background) {
      pthread_attr_set_qos_class_np(&attr, QOS_CLASS_UTILITY, 0);
    }
    create_error = pthread_create(&threads[i], &attr, worker_fn, &args[i]);
    pthread_attr_destroy(&attr);
    if (create_error != 0) {
      break;
    }
    created++;
  }

  /* Wait for the workers made to finish. */
  for (int i = 0; i < created; i++) {
    pthread_join(threads[i], NULL);
  }

  /* Sum totals from all threads. */
  for (int i = 0; i < NUM_THREADS; i++) {
    result->size_bytes += args[i].total_bytes;
    result->disk_bytes += args[i].total_disk_bytes;
    result->file_count += args[i].total_file_count;
    result->folder_count += args[i].total_folder_count;
  }

  result->cancelled = atomic_load(&w->cancelled);
  if (created == 0) {
    result->errnum = create_error;
  } else if (atomic_load(&wq.failed)) {
    result->errnum = ENOMEM;
  } else if (atomic_load(&root->incomplete) && !result->cancelled) {
    result->errnum = atomic_load(&wq.read_errno);
  }

  for (int i = 0; i < NUM_THREADS; i++) {
    walk_dirs_free(args[i].allocated);
  }
  walk_dirs_free(root);
  wq_destroy(&wq);
}

/* ── One item, as the walk counts it ─────────────────────────────── */

/* One item as the walk counts it inside its folder, so a folder's size can be adjusted
   when the item is removed: a file or symlink (not followed) by its data length and
   allocated size, a folder only as one (its contents are the walk's), anything else not
   at all. */
int ft_item_size_of(const char *path, ft_item_size *out) {
  memset(out, 0, sizeof(*out));
  struct stat info;
  if (lstat(path, &info) != 0) {
    return errno;
  }
  out->dev = (int64_t)info.st_dev;
  if (S_ISDIR(info.st_mode)) {
    out->kind = FT_ITEM_FOLDER;
    return 0;
  }
  if (!S_ISREG(info.st_mode) && !S_ISLNK(info.st_mode)) {
    out->kind = FT_ITEM_OTHER;
    return 0;
  }
  out->kind = FT_ITEM_FILE;
  /* The same attributes the walk reads, in bitmap bit order: ALLOCSIZE, then DATALENGTH. */
  struct attrlist list;
  memset(&list, 0, sizeof(list));
  list.bitmapcount = ATTR_BIT_MAP_COUNT;
  list.fileattr = ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH;
  struct {
    uint32_t length;
    off_t alloc_size;
    off_t data_length;
  } __attribute__((aligned(4), packed)) buf;
  if (getattrlist(path, &list, &buf, sizeof(buf), FSOPT_NOFOLLOW) != 0) {
    return errno;
  }
  out->disk_bytes = (int64_t)buf.alloc_size;
  out->size_bytes = (int64_t)buf.data_length;
  return 0;
}

/* ── errno names (packages/native-fs/src/native_errors.c) ─────────── */

#define ERRNO_NAME(name)                                                        \
  case name:                                                                    \
    return #name;

const char *ft_errno_code(int errnum) {
  switch (errnum) {
    ERRNO_NAME(EPERM)
    ERRNO_NAME(ENOENT)
    ERRNO_NAME(ESRCH)
    ERRNO_NAME(EINTR)
    ERRNO_NAME(EIO)
    ERRNO_NAME(ENXIO)
    ERRNO_NAME(E2BIG)
    ERRNO_NAME(ENOEXEC)
    ERRNO_NAME(EBADF)
    ERRNO_NAME(ECHILD)
    ERRNO_NAME(EDEADLK)
    ERRNO_NAME(ENOMEM)
    ERRNO_NAME(EACCES)
    ERRNO_NAME(EFAULT)
    ERRNO_NAME(EBUSY)
    ERRNO_NAME(EEXIST)
    ERRNO_NAME(EXDEV)
    ERRNO_NAME(ENODEV)
    ERRNO_NAME(ENOTDIR)
    ERRNO_NAME(EISDIR)
    ERRNO_NAME(EINVAL)
    ERRNO_NAME(ENFILE)
    ERRNO_NAME(EMFILE)
    ERRNO_NAME(ENOTTY)
    ERRNO_NAME(ETXTBSY)
    ERRNO_NAME(EFBIG)
    ERRNO_NAME(ENOSPC)
    ERRNO_NAME(ESPIPE)
    ERRNO_NAME(EROFS)
    ERRNO_NAME(EMLINK)
    ERRNO_NAME(EPIPE)
    ERRNO_NAME(EDOM)
    ERRNO_NAME(ERANGE)
    ERRNO_NAME(EAGAIN)
    ERRNO_NAME(EINPROGRESS)
    ERRNO_NAME(EALREADY)
    ERRNO_NAME(ENOTSOCK)
    ERRNO_NAME(EDESTADDRREQ)
    ERRNO_NAME(EMSGSIZE)
    ERRNO_NAME(EPROTOTYPE)
    ERRNO_NAME(ENOPROTOOPT)
    ERRNO_NAME(EPROTONOSUPPORT)
    ERRNO_NAME(ENOTSUP)
    ERRNO_NAME(EAFNOSUPPORT)
    ERRNO_NAME(EADDRINUSE)
    ERRNO_NAME(EADDRNOTAVAIL)
    ERRNO_NAME(ENETDOWN)
    ERRNO_NAME(ENETUNREACH)
    ERRNO_NAME(ENETRESET)
    ERRNO_NAME(ECONNABORTED)
    ERRNO_NAME(ECONNRESET)
    ERRNO_NAME(ENOBUFS)
    ERRNO_NAME(EISCONN)
    ERRNO_NAME(ENOTCONN)
    ERRNO_NAME(ETIMEDOUT)
    ERRNO_NAME(ECONNREFUSED)
    ERRNO_NAME(ELOOP)
    ERRNO_NAME(ENAMETOOLONG)
    ERRNO_NAME(EHOSTDOWN)
    ERRNO_NAME(EHOSTUNREACH)
    ERRNO_NAME(ENOTEMPTY)
    ERRNO_NAME(EUSERS)
    ERRNO_NAME(EDQUOT)
    ERRNO_NAME(ESTALE)
    ERRNO_NAME(EREMOTE)
    ERRNO_NAME(ENOLCK)
    ERRNO_NAME(ENOSYS)
    ERRNO_NAME(EOVERFLOW)
    ERRNO_NAME(ECANCELED)
    ERRNO_NAME(EIDRM)
    ERRNO_NAME(ENOMSG)
    ERRNO_NAME(EILSEQ)
    ERRNO_NAME(EBADMSG)
    ERRNO_NAME(ENOLINK)
    ERRNO_NAME(EPROTO)
    ERRNO_NAME(EOPNOTSUPP)
#ifdef ENOTBLK
    ERRNO_NAME(ENOTBLK)
#endif
#ifdef ESOCKTNOSUPPORT
    ERRNO_NAME(ESOCKTNOSUPPORT)
#endif
#ifdef EPFNOSUPPORT
    ERRNO_NAME(EPFNOSUPPORT)
#endif
#ifdef ESHUTDOWN
    ERRNO_NAME(ESHUTDOWN)
#endif
#ifdef ETOOMANYREFS
    ERRNO_NAME(ETOOMANYREFS)
#endif
#ifdef EPROCLIM
    ERRNO_NAME(EPROCLIM)
#endif
#ifdef EBADRPC
    ERRNO_NAME(EBADRPC)
#endif
#ifdef ERPCMISMATCH
    ERRNO_NAME(ERPCMISMATCH)
#endif
#ifdef EPROGUNAVAIL
    ERRNO_NAME(EPROGUNAVAIL)
#endif
#ifdef EPROGMISMATCH
    ERRNO_NAME(EPROGMISMATCH)
#endif
#ifdef EPROCUNAVAIL
    ERRNO_NAME(EPROCUNAVAIL)
#endif
#ifdef EFTYPE
    ERRNO_NAME(EFTYPE)
#endif
#ifdef EAUTH
    ERRNO_NAME(EAUTH)
#endif
#ifdef ENEEDAUTH
    ERRNO_NAME(ENEEDAUTH)
#endif
#ifdef EPWROFF
    ERRNO_NAME(EPWROFF)
#endif
#ifdef EDEVERR
    ERRNO_NAME(EDEVERR)
#endif
#ifdef EBADEXEC
    ERRNO_NAME(EBADEXEC)
#endif
#ifdef EBADARCH
    ERRNO_NAME(EBADARCH)
#endif
#ifdef ESHLIBVERS
    ERRNO_NAME(ESHLIBVERS)
#endif
#ifdef EBADMACHO
    ERRNO_NAME(EBADMACHO)
#endif
#ifdef ENOATTR
    ERRNO_NAME(ENOATTR)
#endif
#ifdef EMULTIHOP
    ERRNO_NAME(EMULTIHOP)
#endif
#ifdef ENODATA
    ERRNO_NAME(ENODATA)
#endif
#ifdef ENOSR
    ERRNO_NAME(ENOSR)
#endif
#ifdef ENOSTR
    ERRNO_NAME(ENOSTR)
#endif
#ifdef ETIME
    ERRNO_NAME(ETIME)
#endif
#ifdef ENOPOLICY
    ERRNO_NAME(ENOPOLICY)
#endif
#ifdef ENOTRECOVERABLE
    ERRNO_NAME(ENOTRECOVERABLE)
#endif
#ifdef EOWNERDEAD
    ERRNO_NAME(EOWNERDEAD)
#endif
#ifdef EQFULL
    ERRNO_NAME(EQFULL)
#endif
  default:
    return "UNKNOWN";
  }
}

#undef ERRNO_NAME
