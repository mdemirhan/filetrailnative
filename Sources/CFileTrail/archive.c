// Archives taken apart and zips made with the system's libarchive, for Swift, which supplies the thread.
//
// macOS ships libarchive (/usr/lib/libarchive.2.dylib, the library behind /usr/bin/tar) without its headers; the two
// in libarchive/ declare its API. Only what that library exports is called: the link fails otherwise.
//
// Only the formats and filters libarchive reads by itself are turned on. Those it would hand to another program
// (zstd, lz4, lrzip…) are not, so nothing outside the app is run.

#include "ft_archive.h"

#include "archive.h"
#include "archive_entry.h"

#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

struct ft_archive_control {
    _Atomic int32_t stop;
    _Atomic int64_t done;
    _Atomic int64_t total;
    _Atomic int64_t items;
    _Atomic int64_t skipped;
};

ft_archive_control *ft_archive_control_create(void) {
    ft_archive_control *control = calloc(1, sizeof(ft_archive_control));
    if (control != NULL) {
        atomic_init(&control->stop, 0);
        atomic_init(&control->done, 0);
        atomic_init(&control->total, 0);
        atomic_init(&control->items, 0);
        atomic_init(&control->skipped, 0);
    }
    return control;
}

void ft_archive_control_free(ft_archive_control *control) { free(control); }

void ft_archive_control_stop(ft_archive_control *control) {
    if (control != NULL) atomic_store(&control->stop, 1);
}

int64_t ft_archive_control_done(const ft_archive_control *control) {
    return control == NULL ? 0 : atomic_load(&control->done);
}

int64_t ft_archive_control_total(const ft_archive_control *control) {
    return control == NULL ? 0 : atomic_load(&control->total);
}

int64_t ft_archive_control_items(const ft_archive_control *control) {
    return control == NULL ? 0 : atomic_load(&control->items);
}

int64_t ft_archive_control_skipped(const ft_archive_control *control) {
    return control == NULL ? 0 : atomic_load(&control->skipped);
}

static int is_stopped(ft_archive_control *control) { return control != NULL && atomic_load(&control->stop); }

/// Adds `by` to the control's `field`, when there is a control.
#define COUNT(control, field, by)                                          \
    do {                                                                   \
        if ((control) != NULL) atomic_fetch_add(&(control)->field, (by)); \
    } while (0)

static void set_message(char *message, size_t size, const char *text) {
    if (message != NULL && size > 0) snprintf(message, size, "%s", text == NULL ? "" : text);
}

/// The quarantine attribute every item made from a downloaded archive carries.
static const char *const quarantine_name = "com.apple.quarantine";

// MARK: Extract

/// `name`, an item's path inside the archive, as it is written under the destination: its `.` parts and empty parts
/// dropped. NULL, to leave it out, for a name from the root (`/etc/…`), one that climbs out (`..`), Finder's
/// `__MACOSX` (its contents are put back on their items already), or nothing at all.
static const char *safe_name(const char *name, char *buffer, size_t size) {
    if (name == NULL || name[0] == '\0' || name[0] == '/') return NULL;
    size_t length = 0;
    const char *part = name;
    while (*part != '\0') {
        const char *end = strchr(part, '/');
        size_t part_length = end == NULL ? strlen(part) : (size_t)(end - part);
        if (part_length == 2 && part[0] == '.' && part[1] == '.') return NULL;
        int skip = part_length == 0 || (part_length == 1 && part[0] == '.');
        if (!skip) {
            if (length == 0 && part_length == 8 && memcmp(part, "__MACOSX", 8) == 0) return NULL;
            if (length + part_length + 2 > size) return NULL;
            if (length > 0) buffer[length++] = '/';
            memcpy(buffer + length, part, part_length);
            length += part_length;
        }
        if (end == NULL) break;
        part = end + 1;
    }
    if (length == 0) return NULL;
    buffer[length] = '\0';
    return buffer;
}

/// `destination/name` in `buffer`; 0 when it doesn't fit.
static int join(const char *destination, const char *name, char *buffer, size_t size) {
    int written = snprintf(buffer, size, "%s/%s", destination, name);
    return written > 0 && (size_t)written < size;
}

/// The archive's words mean it needs a password libarchive wasn't given (zip, RAR, 7z each say it otherwise).
static int asks_for_password(struct archive *reader) {
    if (archive_read_has_encrypted_entries(reader) > 0) return 1;
    const char *text = archive_error_string(reader);
    return text != NULL && (strcasestr(text, "passphrase") != NULL || strcasestr(text, "encrypt") != NULL);
}

/// Gives each item under `root`, not `root` itself, the quarantine `value`. An item that refuses it keeps what it has.
static void quarantine_tree(const char *root, const char *value, size_t length) {
    char *const roots[] = {(char *)root, NULL};
    FTS *tree = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) return;
    FTSENT *node;
    while ((node = fts_read(tree)) != NULL) {
        if (node->fts_level == 0 || node->fts_info == FTS_DP) continue;
        setxattr(node->fts_path, quarantine_name, value, length, 0, XATTR_NOFOLLOW);
    }
    fts_close(tree);
}

static struct archive *new_reader(int raw) {
    struct archive *reader = archive_read_new();
    if (reader == NULL) return NULL;
    archive_read_support_filter_gzip(reader);
    archive_read_support_filter_bzip2(reader);
    archive_read_support_filter_xz(reader);
    archive_read_support_filter_lzma(reader);
    archive_read_support_filter_compress(reader);
    if (raw) {
        archive_read_support_format_raw(reader);
    } else {
        archive_read_support_format_zip(reader);
        archive_read_support_format_7zip(reader);
        archive_read_support_format_rar(reader);
        archive_read_support_format_rar5(reader);
        archive_read_support_format_tar(reader);
        archive_read_support_format_xar(reader);
    }
    return reader;
}

int ft_archive_extract(
    const char *archive, const char *destination, const char *raw_name, int quarantine,
    ft_archive_control *control, char *message, size_t message_size) {
    set_message(message, message_size, NULL);
    // The guard against writing through links checks every folder of the path, so the destination is given as its
    // real path: `/var/folders/…` is a link to `/private/var/folders/…`.
    char real_destination[PATH_MAX];
    if (realpath(destination, real_destination) == NULL) return errno;
    destination = real_destination;
    int fd = open(archive, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return errno;
    struct stat stats;
    if (fstat(fd, &stats) != 0) {
        int error = errno;
        close(fd);
        return error;
    }
    if (control != NULL) atomic_store(&control->total, (int64_t)stats.st_size);

    char quarantine_value[1024];
    ssize_t quarantine_length = 0;
    if (quarantine) {
        quarantine_length = fgetxattr(fd, quarantine_name, quarantine_value, sizeof(quarantine_value), 0, 0);
        if (quarantine_length < 0) quarantine_length = 0;
    }

    struct archive *reader = new_reader(raw_name != NULL);
    struct archive *writer = archive_write_disk_new();
    if (reader == NULL || writer == NULL) {
        if (reader != NULL) archive_read_free(reader);
        if (writer != NULL) archive_write_free(writer);
        close(fd);
        return ENOMEM;
    }
    // No owner (it isn't ours to give), no file flags (a locked item couldn't be undone), and nothing replaced.
    archive_write_disk_set_options(
        writer, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_XATTR | ARCHIVE_EXTRACT_MAC_METADATA
                    | ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_SECURE_SYMLINKS
                    | ARCHIVE_EXTRACT_NO_OVERWRITE);

    int result = 0;
    if (archive_read_open_fd(reader, fd, 1 << 16) != ARCHIVE_OK) {
        set_message(message, message_size, archive_error_string(reader));
        result = asks_for_password(reader) ? FT_ARCHIVE_NEEDS_PASSWORD : FT_ARCHIVE_UNREADABLE;
    } else if (raw_name != NULL && archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE) {
        // A file that isn't compressed at all: "raw" would copy it as it is.
        result = FT_ARCHIVE_UNREADABLE;
    }

    char clean[PATH_MAX];
    char path[PATH_MAX * 2];
    char clean_link[PATH_MAX];
    char link_path[PATH_MAX * 2];
    while (result == 0) {
        struct archive_entry *entry;
        int status = archive_read_next_header(reader, &entry);
        if (status == ARCHIVE_EOF) break;
        if (status < ARCHIVE_WARN) {
            set_message(message, message_size, archive_error_string(reader));
            result = asks_for_password(reader) ? FT_ARCHIVE_NEEDS_PASSWORD : FT_ARCHIVE_UNREADABLE;
            break;
        }
        if (is_stopped(control)) {
            result = ECANCELED;
            break;
        }
        if (archive_entry_is_encrypted(entry)) {
            result = FT_ARCHIVE_NEEDS_PASSWORD;
            break;
        }
        const char *name = safe_name(raw_name != NULL ? raw_name : archive_entry_pathname(entry), clean, sizeof(clean));
        if (name == NULL || !join(destination, name, path, sizeof(path))) {
            COUNT(control, skipped, 1);
            continue;
        }
        const char *hardlink = archive_entry_hardlink(entry);
        if (hardlink != NULL) {
            const char *target = safe_name(hardlink, clean_link, sizeof(clean_link));
            if (target == NULL || !join(destination, target, link_path, sizeof(link_path))) {
                COUNT(control, skipped, 1);
                continue;
            }
            archive_entry_copy_hardlink(entry, link_path);
        }
        archive_entry_copy_pathname(entry, path);
        archive_entry_set_perm(entry, archive_entry_perm(entry) & 0777);

        status = archive_write_header(writer, entry);
        if (status < ARCHIVE_WARN) {
            int error = archive_errno(writer);
            if (error == EEXIST) {
                // A second item of a name already written (or of one a disk that ignores case takes for it).
                COUNT(control, skipped, 1);
                continue;
            }
            set_message(message, message_size, archive_error_string(writer));
            result = error > 0 ? error : EIO;
            break;
        }
        const void *block;
        size_t length;
        la_int64_t offset;
        while ((status = archive_read_data_block(reader, &block, &length, &offset)) == ARCHIVE_OK) {
            if (is_stopped(control)) {
                result = ECANCELED;
                break;
            }
            if (archive_write_data_block(writer, block, length, offset) < ARCHIVE_WARN) {
                int error = archive_errno(writer);
                set_message(message, message_size, archive_error_string(writer));
                result = error > 0 ? error : EIO;
                break;
            }
            if (control != NULL) atomic_store(&control->done, archive_filter_bytes(reader, -1));
        }
        if (result != 0) break;
        if (status != ARCHIVE_EOF && status < ARCHIVE_WARN) {
            set_message(message, message_size, archive_error_string(reader));
            result = asks_for_password(reader) ? FT_ARCHIVE_NEEDS_PASSWORD : FT_ARCHIVE_UNREADABLE;
            break;
        }
        if (archive_write_finish_entry(writer) < ARCHIVE_WARN) {
            int error = archive_errno(writer);
            set_message(message, message_size, archive_error_string(writer));
            result = error > 0 ? error : EIO;
            break;
        }
        COUNT(control, items, 1);
        if (control != NULL) atomic_store(&control->done, archive_filter_bytes(reader, -1));
    }
    // Closing sets the folders' dates and permissions, which waited for their contents.
    if (archive_write_close(writer) < ARCHIVE_WARN && result == 0) {
        int error = archive_errno(writer);
        set_message(message, message_size, archive_error_string(writer));
        result = error > 0 ? error : EIO;
    }
    archive_write_free(writer);
    archive_read_free(reader);
    close(fd);
    if (result == 0 && ft_archive_control_items(control) == 0) result = FT_ARCHIVE_EMPTY;
    if (result == 0 && quarantine_length > 0) {
        quarantine_tree(destination, quarantine_value, (size_t)quarantine_length);
    }
    return result;
}

// MARK: Compress

/// The bytes of the regular files under `path`, links not followed.
static int64_t data_bytes(const char *path) {
    char *const roots[] = {(char *)path, NULL};
    FTS *tree = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) return 0;
    int64_t total = 0;
    FTSENT *node;
    while ((node = fts_read(tree)) != NULL) {
        if (node->fts_info == FTS_F && node->fts_statp != NULL) total += (int64_t)node->fts_statp->st_size;
    }
    fts_close(tree);
    return total;
}

/// Finder's place for `relative`'s attributes: `__MACOSX/dir/._name`, `__MACOSX/._name` at the top.
static int sidecar_name(const char *relative, char *buffer, size_t size) {
    char trimmed[PATH_MAX];
    if (snprintf(trimmed, sizeof(trimmed), "%s", relative) >= (int)sizeof(trimmed)) return 0;
    size_t length = strlen(trimmed);
    while (length > 0 && trimmed[length - 1] == '/') trimmed[--length] = '\0';
    char *slash = strrchr(trimmed, '/');
    int written;
    if (slash == NULL) {
        written = snprintf(buffer, size, "__MACOSX/._%s", trimmed);
    } else {
        *slash = '\0';
        written = snprintf(buffer, size, "__MACOSX/%s/._%s", trimmed, slash + 1);
    }
    return written > 0 && (size_t)written < size;
}

/// libarchive's errno for what went wrong, EIO when it gave none.
static int writer_error(struct archive *writer, char *message, size_t size) {
    int error = archive_errno(writer);
    set_message(message, size, archive_error_string(writer));
    return error > 0 ? error : EIO;
}

/// Writes the regular file `source` as the data of the entry just started; ECANCELED when stopped.
static int write_file_data(
    struct archive *writer, const char *source, ft_archive_control *control, char *message, size_t size) {
    int fd = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno;
    static const size_t chunk = 1 << 17;
    char *buffer = malloc(chunk);
    if (buffer == NULL) {
        close(fd);
        return ENOMEM;
    }
    int result = 0;
    for (;;) {
        if (is_stopped(control)) {
            result = ECANCELED;
            break;
        }
        ssize_t count_read = read(fd, buffer, chunk);
        if (count_read < 0) {
            if (errno == EINTR) continue;
            result = errno;
            break;
        }
        if (count_read == 0) break;
        if (archive_write_data(writer, buffer, (size_t)count_read) < 0) {
            result = writer_error(writer, message, size);
            break;
        }
        COUNT(control, done, count_read);
    }
    free(buffer);
    close(fd);
    return result;
}

/// Adds the item `full` and everything in it, named from `prefix_length` on.
static int compress_item(
    struct archive *writer, const char *full, size_t prefix_length, ft_archive_control *control, char *message,
    size_t size) {
    struct archive *disk = archive_read_disk_new();
    if (disk == NULL) return ENOMEM;
    archive_read_disk_set_behavior(disk, ARCHIVE_READDISK_MAC_COPYFILE | ARCHIVE_READDISK_NO_TRAVERSE_MOUNTS);
    archive_read_disk_set_symlink_physical(disk);
    if (archive_read_disk_open(disk, full) != ARCHIVE_OK) {
        int error = archive_errno(disk);
        set_message(message, size, archive_error_string(disk));
        archive_read_free(disk);
        return error > 0 ? error : EIO;
    }
    struct archive_entry *entry = archive_entry_new();
    struct archive_entry *sidecar = archive_entry_new();
    int result = entry == NULL || sidecar == NULL ? ENOMEM : 0;
    char relative[PATH_MAX + 1];
    char sidecar_path[PATH_MAX + 16];
    while (result == 0) {
        archive_entry_clear(entry);
        int status = archive_read_next_header2(disk, entry);
        if (status == ARCHIVE_EOF) break;
        if (status < ARCHIVE_WARN) {
            int error = archive_errno(disk);
            set_message(message, size, archive_error_string(disk));
            result = error > 0 ? error : EIO;
            break;
        }
        if (is_stopped(control)) {
            result = ECANCELED;
            break;
        }
        archive_read_disk_descend(disk);
        mode_t type = archive_entry_filetype(entry);
        if (type != AE_IFREG && type != AE_IFDIR && type != AE_IFLNK) {
            COUNT(control, skipped, 1);
            continue;
        }
        const char *path = archive_entry_pathname(entry);
        if (path == NULL || strlen(path) <= prefix_length) {
            result = EINVAL;
            break;
        }
        int written = snprintf(relative, sizeof(relative), "%s%s", path + prefix_length, type == AE_IFDIR ? "/" : "");
        if (written <= 0 || (size_t)written >= sizeof(relative)) {
            result = ENAMETOOLONG;
            break;
        }
        // Read before the entry is changed: what Finder puts in __MACOSX, as copyfile packs it.
        size_t metadata_length = 0;
        const void *metadata = archive_entry_mac_metadata(entry, &metadata_length);
        char *metadata_copy = NULL;
        if (metadata != NULL && metadata_length > 0) {
            metadata_copy = malloc(metadata_length);
            if (metadata_copy == NULL) {
                result = ENOMEM;
                break;
            }
            memcpy(metadata_copy, metadata, metadata_length);
        }
        char source[PATH_MAX];
        snprintf(source, sizeof(source), "%s", archive_entry_sourcepath(entry) ? archive_entry_sourcepath(entry) : path);
        time_t modified = archive_entry_mtime(entry);
        archive_entry_copy_pathname(entry, relative);
        if (archive_write_header(writer, entry) < ARCHIVE_WARN) {
            result = writer_error(writer, message, size);
        } else if (type == AE_IFREG && archive_entry_size(entry) > 0) {
            result = write_file_data(writer, source, control, message, size);
        }
        if (result == 0 && archive_write_finish_entry(writer) < ARCHIVE_WARN) {
            result = writer_error(writer, message, size);
        }
        if (result == 0) COUNT(control, items, 1);
        if (result == 0 && metadata_copy != NULL && sidecar_name(relative, sidecar_path, sizeof(sidecar_path))) {
            archive_entry_clear(sidecar);
            archive_entry_copy_pathname(sidecar, sidecar_path);
            archive_entry_set_filetype(sidecar, AE_IFREG);
            archive_entry_set_perm(sidecar, 0644);
            archive_entry_set_size(sidecar, (la_int64_t)metadata_length);
            archive_entry_set_mtime(sidecar, modified, 0);
            if (archive_write_header(writer, sidecar) < ARCHIVE_WARN
                || archive_write_data(writer, metadata_copy, metadata_length) < 0
                || archive_write_finish_entry(writer) < ARCHIVE_WARN) {
                result = writer_error(writer, message, size);
            }
        }
        free(metadata_copy);
    }
    if (sidecar != NULL) archive_entry_free(sidecar);
    if (entry != NULL) archive_entry_free(entry);
    archive_read_free(disk);
    return result;
}

int ft_archive_compress_zip(
    const char *base, const char *const *names, size_t count_names, const char *destination,
    ft_archive_control *control, char *message, size_t message_size) {
    set_message(message, message_size, NULL);
    if (count_names == 0) return EINVAL;
    char full[PATH_MAX * 2];
    int64_t total = 0;
    for (size_t index = 0; index < count_names; index++) {
        if (!join(base, names[index], full, sizeof(full))) return ENAMETOOLONG;
        total += data_bytes(full);
    }
    if (control != NULL) atomic_store(&control->total, total);

    int fd = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) return errno;
    struct archive *writer = archive_write_new();
    if (writer == NULL) {
        close(fd);
        return ENOMEM;
    }
    archive_write_set_format_zip(writer);
    // Names as UTF-8, marked so: Windows reads them right, as Finder's zips don't let it.
    archive_write_set_options(writer, "zip:hdrcharset=UTF-8");
    int result = 0;
    if (archive_write_open_fd(writer, fd) != ARCHIVE_OK) result = writer_error(writer, message, message_size);
    size_t prefix_length = strlen(base) + (base[strlen(base) - 1] == '/' ? 0 : 1);
    for (size_t index = 0; result == 0 && index < count_names; index++) {
        join(base, names[index], full, sizeof(full));
        result = compress_item(writer, full, prefix_length, control, message, message_size);
    }
    // The zip's directory is written on close; a full disk may only show then.
    if (archive_write_close(writer) < ARCHIVE_WARN && result == 0) {
        result = writer_error(writer, message, message_size);
    }
    archive_write_free(writer);
    if (close(fd) != 0 && result == 0) result = errno;
    return result;
}
