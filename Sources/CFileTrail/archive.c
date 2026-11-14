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

#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/xattr.h>
#include <unistd.h>

struct ft_archive_control {
    _Atomic int32_t stop;
    _Atomic int64_t done;
    _Atomic int64_t total;
    _Atomic int64_t items;
    _Atomic int64_t skipped;
    /// The destination is taken for a disk that keeps no extended attributes (for tests).
    _Atomic int32_t no_attributes;
};

ft_archive_control *ft_archive_control_create(void) {
    ft_archive_control *control = calloc(1, sizeof(ft_archive_control));
    if (control != NULL) {
        atomic_init(&control->stop, 0);
        atomic_init(&control->done, 0);
        atomic_init(&control->total, 0);
        atomic_init(&control->items, 0);
        atomic_init(&control->skipped, 0);
        atomic_init(&control->no_attributes, 0);
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

void ft_archive_control_take_disk_as_keeping_no_attributes(ft_archive_control *control) {
    if (control != NULL) atomic_store(&control->no_attributes, 1);
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

/// The quarantine attribute every item made from a downloaded archive carries.
static const char *const quarantine_name = "com.apple.quarantine";

// MARK: Extract
//
// The archive is read with libarchive and its items are written here, one system call at a time. libarchive's own
// writer to disk clears the process's umask around every item it makes, so a file or folder another thread made at
// that moment would be open to everyone; nothing here touches the umask.
//
// Every item is reached from the destination folder one part of its path at a time, each part opened without
// following a link, and made with a call that fails when the name is taken. So nothing is written through a link an
// earlier item of the archive made, and nothing is replaced.

/// What a name inside an archive comes to.
enum { NAME_USED = 1, NAME_NOTHING = 0, NAME_REFUSED = -1 };

/// How many bytes the UTF-8 character at `bytes` takes; 0 when what is there isn't one (a stray byte, a longer form
/// than needed, half of a pair, past the last character).
static size_t utf8_length(const unsigned char *bytes, size_t available) {
    unsigned char first = bytes[0];
    if (first < 0x80) return 1;
    size_t length;
    uint32_t value;
    uint32_t least;
    if (first >= 0xC2 && first <= 0xDF) {
        length = 2;
        value = first & 0x1F;
        least = 0x80;
    } else if (first >= 0xE0 && first <= 0xEF) {
        length = 3;
        value = first & 0x0F;
        least = 0x800;
    } else if (first >= 0xF0 && first <= 0xF4) {
        length = 4;
        value = first & 0x07;
        least = 0x10000;
    } else {
        return 0;
    }
    if (available < length) return 0;
    for (size_t index = 1; index < length; index++) {
        if ((bytes[index] & 0xC0) != 0x80) return 0;
        value = (value << 6) | (bytes[index] & 0x3F);
    }
    if (value < least || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) return 0;
    return length;
}

/// `name`, an item's path inside the archive, as it is written under the destination: its `.` parts and empty parts
/// dropped, and every byte that isn't UTF-8 written as `%XX` (a zip made where names aren't UTF-8 doesn't say which
/// encoding they are in, and the disk takes only UTF-8). NAME_REFUSED, to leave the item out, for a name from the
/// root (`/etc/…`), one that climbs out (`..`), Finder's `__MACOSX` (its contents are put back on their items
/// already) and one too long; NAME_NOTHING for a name with nothing in it (`./`, the folder a tar was made in).
static int safe_name(const char *name, char *buffer, size_t size) {
    if (name == NULL || name[0] == '\0') return NAME_NOTHING;
    if (name[0] == '/') return NAME_REFUSED;
    static const char digits[] = "0123456789ABCDEF";
    size_t length = 0;
    const char *part = name;
    while (*part != '\0') {
        const char *end = strchr(part, '/');
        size_t part_length = end == NULL ? strlen(part) : (size_t)(end - part);
        if (part_length == 2 && part[0] == '.' && part[1] == '.') return NAME_REFUSED;
        int skip = part_length == 0 || (part_length == 1 && part[0] == '.');
        if (!skip) {
            if (length == 0 && part_length == 8 && memcmp(part, "__MACOSX", 8) == 0) return NAME_REFUSED;
            // Room for every byte written as three, the slash and the end.
            if (length + part_length * 3 + 2 > size) return NAME_REFUSED;
            if (length > 0) buffer[length++] = '/';
            const unsigned char *bytes = (const unsigned char *)part;
            size_t index = 0;
            while (index < part_length) {
                size_t count = utf8_length(bytes + index, part_length - index);
                if (count == 0) {
                    buffer[length++] = '%';
                    buffer[length++] = digits[bytes[index] >> 4];
                    buffer[length++] = digits[bytes[index] & 0x0F];
                    index++;
                } else {
                    memcpy(buffer + length, bytes + index, count);
                    length += count;
                    index += count;
                }
            }
        }
        if (end == NULL) break;
        part = end + 1;
    }
    if (length == 0) return NAME_NOTHING;
    buffer[length] = '\0';
    return NAME_USED;
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

/// What a failed read of the archive is reported as.
static int reader_error(struct archive *reader) {
    return asks_for_password(reader) ? FT_ARCHIVE_NEEDS_PASSWORD : FT_ARCHIVE_UNREADABLE;
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

/// An item's dates as the archive gives them.
struct item_times {
    int has_modified;
    int has_created;
    struct timeval accessed;
    struct timeval modified;
    struct timeval created;
};

/// A folder made while extracting. Its permissions and dates wait until everything inside it is written: a folder
/// that can't be written to couldn't be filled, and filling it changes its date.
struct made_folder {
    /// Its path under the destination.
    char *path;
    ino_t inode;
    /// An item of the archive is this folder; otherwise it was only made on the way to an item inside it, and keeps
    /// the permissions a new folder gets.
    int given;
    mode_t mode;
    struct item_times times;
};

/// One archive being taken apart.
struct extraction {
    /// The destination folder, open.
    int root;
    ft_archive_control *control;
    const char *quarantine;
    size_t quarantine_length;
    struct made_folder *folders;
    size_t count_folders;
    size_t room_folders;
    /// The folders by inode: each slot holds an index into `folders` plus one, 0 when empty.
    uint32_t *slots;
    size_t count_slots;
    /// The folder the last item went into, kept open for the next one, and its path under the destination.
    char parent[PATH_MAX];
    int parent_fd;
    /// A file with no name, for an item's Mac metadata on its way to the item; -1 until one is needed.
    int scratch;
    /// Room for an item's quarantine read back, one byte longer than the archive's.
    char *quarantine_check;
    /// A folder made on the way to an item refused the archive's quarantine: the extraction fails.
    int unquarantined;
};

/// The item couldn't be made as the archive names it, and is left out.
enum { ITEM_LEFT_OUT = -100 };

/// A failure to make an item that is the item's own (its name is taken, runs through a link or a file, is too long
/// or one the disk won't take; what a hard link names isn't there) leaves out that item; any other is returned.
static int left_out_or(int error) {
    switch (error) {
    case EEXIST:
    case ELOOP:
    case ENOTDIR:
    case EISDIR:
    case ENAMETOOLONG:
    case EILSEQ:
    case ENOENT:
    case EINVAL:
    case EMLINK: return ITEM_LEFT_OUT;
    default: return error;
    }
}

static size_t slot_of(const struct extraction *extraction, ino_t inode) {
    return (size_t)(((uint64_t)inode * 0x9E3779B97F4A7C15ULL) >> 32) & (extraction->count_slots - 1);
}

static void fill_slot(struct extraction *extraction, size_t index) {
    size_t slot = slot_of(extraction, extraction->folders[index].inode);
    while (extraction->slots[slot] != 0) slot = (slot + 1) & (extraction->count_slots - 1);
    extraction->slots[slot] = (uint32_t)(index + 1);
}

/// The folder made here whose inode is `inode`, or NULL.
static struct made_folder *find_folder(const struct extraction *extraction, ino_t inode) {
    if (extraction->count_slots == 0) return NULL;
    size_t slot = slot_of(extraction, inode);
    while (extraction->slots[slot] != 0) {
        struct made_folder *folder = &extraction->folders[extraction->slots[slot] - 1];
        if (folder->inode == inode) return folder;
        slot = (slot + 1) & (extraction->count_slots - 1);
    }
    return NULL;
}

/// Remembers a folder just made, at the first `length` bytes of `path`; NULL when out of memory.
static struct made_folder *note_folder(struct extraction *extraction, const char *path, size_t length, ino_t inode) {
    if (extraction->count_folders == extraction->room_folders) {
        size_t room = extraction->room_folders == 0 ? 64 : extraction->room_folders * 2;
        struct made_folder *grown = realloc(extraction->folders, room * sizeof(struct made_folder));
        if (grown == NULL) return NULL;
        extraction->folders = grown;
        extraction->room_folders = room;
    }
    if ((extraction->count_folders + 1) * 2 > extraction->count_slots) {
        size_t count = extraction->count_slots == 0 ? 128 : extraction->count_slots * 2;
        uint32_t *slots = calloc(count, sizeof(uint32_t));
        if (slots == NULL) return NULL;
        free(extraction->slots);
        extraction->slots = slots;
        extraction->count_slots = count;
        for (size_t index = 0; index < extraction->count_folders; index++) fill_slot(extraction, index);
    }
    struct made_folder *folder = &extraction->folders[extraction->count_folders];
    memset(folder, 0, sizeof(*folder));
    folder->path = strndup(path, length);
    if (folder->path == NULL) return NULL;
    folder->inode = inode;
    fill_slot(extraction, extraction->count_folders++);
    return folder;
}

/// Gives the open item the archive's quarantine, when it has one, and reads it back: 0 when the item has it, and
/// otherwise FT_ARCHIVE_NOT_QUARANTINED.
static int quarantine_item(const struct extraction *extraction, int fd) {
    size_t length = extraction->quarantine_length;
    if (length == 0) return 0;
    fsetxattr(fd, quarantine_name, extraction->quarantine, length, 0, 0);
    ssize_t got = fgetxattr(fd, quarantine_name, extraction->quarantine_check, length + 1, 0, 0);
    if (got == (ssize_t)length && memcmp(extraction->quarantine_check, extraction->quarantine, length) == 0) return 0;
    return FT_ARCHIVE_NOT_QUARANTINED;
}

static const int open_folder_flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;

/// Opens the folder at the first `length` bytes of `path` under the destination, one part at a time and never
/// through a link: a part that is a link or a file fails (ELOOP, ENOTDIR). With `make`, parts that aren't there are
/// made. The caller closes what it gets; -1 with errno when it fails.
static int open_folder(struct extraction *extraction, const char *path, size_t length, int make) {
    int fd = openat(extraction->root, ".", open_folder_flags);
    if (fd < 0) return -1;
    char part[PATH_MAX];
    size_t start = 0;
    while (start < length) {
        size_t end = start;
        while (end < length && path[end] != '/') end++;
        if (end - start >= sizeof(part)) {
            close(fd);
            errno = ENAMETOOLONG;
            return -1;
        }
        memcpy(part, path + start, end - start);
        part[end - start] = '\0';
        int next = openat(fd, part, open_folder_flags);
        int error = errno;
        if (next < 0 && error == ENOENT && make) {
            if (mkdirat(fd, part, 0777) == 0) {
                next = openat(fd, part, open_folder_flags);
                error = errno;
                struct stat stats;
                if (next >= 0) {
                    if (fstat(next, &stats) != 0 || note_folder(extraction, path, end, stats.st_ino) == NULL) {
                        close(next);
                        next = -1;
                        error = ENOMEM;
                    } else if (quarantine_item(extraction, next) != 0) {
                        close(next);
                        next = -1;
                        error = EPERM;
                        extraction->unquarantined = 1;
                    }
                }
            } else {
                error = errno;
            }
        }
        close(fd);
        if (next < 0) {
            errno = error;
            return -1;
        }
        fd = next;
        start = end + 1;
    }
    return fd;
}

/// The open folder the item `name` goes into, made when it isn't there, and in `leaf` the item's own name. The
/// extraction keeps it open; -1 with errno when it fails.
static int parent_of(struct extraction *extraction, const char *name, const char **leaf) {
    const char *slash = strrchr(name, '/');
    if (slash == NULL) {
        *leaf = name;
        return extraction->root;
    }
    *leaf = slash + 1;
    size_t length = (size_t)(slash - name);
    if (extraction->parent_fd >= 0 && strlen(extraction->parent) == length
        && memcmp(extraction->parent, name, length) == 0) {
        return extraction->parent_fd;
    }
    if (extraction->parent_fd >= 0) close(extraction->parent_fd);
    extraction->parent_fd = open_folder(extraction, name, length, 1);
    if (extraction->parent_fd >= 0) {
        memcpy(extraction->parent, name, length);
        extraction->parent[length] = '\0';
    }
    return extraction->parent_fd;
}

static struct timeval time_of(time_t seconds, long nanoseconds) {
    struct timeval time = {.tv_sec = seconds, .tv_usec = (suseconds_t)(nanoseconds / 1000)};
    return time;
}

static struct item_times times_of(struct archive_entry *entry) {
    struct item_times times;
    memset(&times, 0, sizeof(times));
    times.has_modified = archive_entry_mtime_is_set(entry);
    if (!times.has_modified) return times;
    times.modified = time_of(archive_entry_mtime(entry), archive_entry_mtime_nsec(entry));
    if (archive_entry_atime_is_set(entry)) {
        times.accessed = time_of(archive_entry_atime(entry), archive_entry_atime_nsec(entry));
    } else {
        gettimeofday(&times.accessed, NULL);
    }
    times.has_created = archive_entry_birthtime_is_set(entry);
    if (times.has_created) {
        times.created = time_of(archive_entry_birthtime(entry), archive_entry_birthtime_nsec(entry));
    }
    return times;
}

/// Gives the open item the archive's dates for it. A date that can't be set is left as it is.
static void set_times(int fd, const struct item_times *times) {
    if (!times->has_modified) return;
    // The disk moves an item's date of creation back to a date of change set before it, and not forward again.
    if (times->has_created) {
        struct timeval created[2] = {times->accessed, times->created};
        futimes(fd, created);
    }
    struct timeval both[2] = {times->accessed, times->modified};
    futimes(fd, both);
}

/// A new file with no name in the user's temporary folder; -1 when it can't be made.
static int scratch_file(void) {
    char path[PATH_MAX];
    size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, path, sizeof(path));
    if (length == 0 || length + 32 > sizeof(path)) snprintf(path, sizeof(path), "/tmp/");
    strlcat(path, "filetrail-archive.XXXXXX", sizeof(path));
    int fd = mkstemp(path);
    if (fd < 0) return -1;
    unlink(path);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

static int write_all(int fd, const void *data, size_t length, off_t offset) {
    const char *bytes = data;
    while (length > 0) {
        ssize_t written = pwrite(fd, bytes, length, offset);
        if (written < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        bytes += written;
        length -= (size_t)written;
        offset += written;
    }
    return 0;
}

/// An extended attribute an archive may not put on an item: an access rule as text (as copyfile packs one), or one
/// of the system's own.
static int is_access_rule(const char *name) {
    return strcmp(name, "com.apple.acl.text") == 0 || strncmp(name, "com.apple.system.", 17) == 0;
}

/// Puts the extended attributes of the open file `from` on the open item `to`, but for access rules. One that
/// can't be read or put on is left off.
static void copy_attributes(int from, int to) {
    ssize_t size = flistxattr(from, NULL, 0, 0);
    if (size <= 0) return;
    char *names = malloc((size_t)size);
    if (names == NULL) return;
    size = flistxattr(from, names, (size_t)size, 0);
    for (ssize_t start = 0; start < size;) {
        const char *name = names + start;
        size_t name_length = strnlen(name, (size_t)(size - start));
        start += (ssize_t)name_length + 1;
        if (is_access_rule(name)) continue;
        ssize_t length = fgetxattr(from, name, NULL, 0, 0, 0);
        if (length < 0) continue;
        void *value = malloc(length > 0 ? (size_t)length : 1);
        if (value == NULL) continue;
        length = fgetxattr(from, name, value, (size_t)length, 0, 0);
        if (length >= 0) fsetxattr(to, name, value, (size_t)length, 0, 0);
        free(value);
    }
    free(names);
}

/// Puts on the open item, just made and still its owner's to write, what the archive keeps for it besides its data:
/// its extended attributes and its Mac metadata (the resource fork, Finder's information and attributes, which
/// Finder's zips keep in `__MACOSX` and tars in a `._` file), and last the archive's quarantine, so that none of
/// those can take it off. What the item refuses is left off, but for the quarantine: returns 0, or
/// FT_ARCHIVE_NOT_QUARANTINED.
///
/// Access rules (ACLs) are never put on: one that denies writing attributes, inherited by everything in a folder,
/// would keep the quarantine off, and one that denies deleting would keep a stopped extraction, or Undo, from
/// clearing the items away.
static int dress_item(struct extraction *extraction, int fd, struct archive_entry *entry) {
    if (archive_entry_xattr_reset(entry) > 0) {
        const char *name;
        const void *value;
        size_t size;
        while (archive_entry_xattr_next(entry, &name, &value, &size) == ARCHIVE_OK) {
            if (name != NULL && value != NULL && !is_access_rule(name)) fsetxattr(fd, name, value, size, 0, 0);
        }
    }
    size_t metadata_length = 0;
    const void *metadata = archive_entry_mac_metadata(entry, &metadata_length);
    if (metadata != NULL && metadata_length > 0) {
        if (extraction->scratch < 0) extraction->scratch = scratch_file();
        int scratch = extraction->scratch;
        if (scratch >= 0 && ftruncate(scratch, 0) == 0 && write_all(scratch, metadata, metadata_length, 0) == 0
            && lseek(scratch, 0, SEEK_SET) == 0) {
            // copyfile puts the access rules it finds on whatever it unpacks onto, asked to or not: it unpacks onto
            // a file of its own, with no name, and only the attributes go on from there.
            int unpacked = scratch_file();
            if (unpacked >= 0) {
                if (fcopyfile(scratch, unpacked, NULL, COPYFILE_UNPACK | COPYFILE_XATTR) == 0) {
                    copy_attributes(unpacked, fd);
                }
                close(unpacked);
            }
        }
    }
    return quarantine_item(extraction, fd);
}

/// Makes the file `leaf` in the open folder `parent` and writes the item's data to it.
static int make_file(
    struct extraction *extraction, struct archive *reader, struct archive_entry *entry, int parent, const char *leaf) {
    // Its owner's alone until it is whole. Its own permissions come last: they may not let it be written.
    int fd = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return left_out_or(errno);
    int result = 0;
    off_t end = 0;
    const void *block;
    size_t length;
    la_int64_t offset;
    int status;
    while ((status = archive_read_data_block(reader, &block, &length, &offset)) == ARCHIVE_OK) {
        if (is_stopped(extraction->control)) {
            result = ECANCELED;
            break;
        }
        result = write_all(fd, block, length, (off_t)offset);
        if (result != 0) break;
        if ((off_t)offset + (off_t)length > end) end = (off_t)offset + (off_t)length;
        if (extraction->control != NULL) atomic_store(&extraction->control->done, archive_filter_bytes(reader, -1));
    }
    if (result == 0 && status != ARCHIVE_EOF && status < ARCHIVE_WARN) result = reader_error(reader);
    // A file that ends in a hole: nothing was written there.
    if (result == 0 && archive_entry_size_is_set(entry) && archive_entry_size(entry) > end) {
        if (ftruncate(fd, (off_t)archive_entry_size(entry)) != 0) result = errno;
    }
    if (result == 0) result = dress_item(extraction, fd, entry);
    if (result == 0) {
        if (fchmod(fd, archive_entry_perm(entry) & 0777) != 0) result = errno;
        struct item_times times = times_of(entry);
        set_times(fd, &times);
    }
    if (close(fd) != 0 && result == 0) result = errno;
    return result;
}

/// Makes the folder `leaf` in the open folder `parent`; `name` is its path under the destination. A folder made
/// already on the way to an item inside it becomes the archive's.
static int make_folder(
    struct extraction *extraction, struct archive_entry *entry, int parent, const char *leaf, const char *name) {
    int made = mkdirat(parent, leaf, 0700) == 0;
    if (!made && errno != EEXIST) return left_out_or(errno);
    int fd = openat(parent, leaf, open_folder_flags);
    if (fd < 0) return left_out_or(errno);
    struct stat stats;
    if (fstat(fd, &stats) != 0) {
        int error = errno;
        close(fd);
        return error;
    }
    struct made_folder *folder;
    if (made) {
        folder = note_folder(extraction, name, strlen(name), stats.st_ino);
        if (folder == NULL) {
            close(fd);
            return ENOMEM;
        }
    } else {
        folder = find_folder(extraction, stats.st_ino);
        if (folder == NULL || folder->given) {
            close(fd);
            return ITEM_LEFT_OUT;
        }
    }
    folder->given = 1;
    folder->mode = archive_entry_perm(entry) & 0777;
    folder->times = times_of(entry);
    int result = dress_item(extraction, fd, entry);
    close(fd);
    return result;
}

/// Makes the link `leaf` in the open folder `parent`. Where it points is the archive's to say: it is never followed
/// here. A link that refuses the quarantine goes without: it runs nothing itself, what it points to is checked when
/// opened, and some disks keep no attributes on a link.
static int make_symlink(struct extraction *extraction, struct archive_entry *entry, int parent, const char *leaf) {
    const char *target = archive_entry_symlink(entry);
    if (target == NULL) target = archive_entry_symlink_utf8(entry);
    if (target == NULL || target[0] == '\0') return ITEM_LEFT_OUT;
    if (symlinkat(target, parent, leaf) != 0) return left_out_or(errno);
    int fd = openat(parent, leaf, O_RDONLY | O_SYMLINK | O_CLOEXEC);
    if (fd >= 0) {
        dress_item(extraction, fd, entry);
        fchmod(fd, archive_entry_perm(entry) & 0777);
        struct item_times times = times_of(entry);
        set_times(fd, &times);
        close(fd);
    }
    return 0;
}

/// Makes `leaf` in the open folder `parent` another name of the file `target` (a path inside the archive), which an
/// earlier item made. Only of a regular file under the destination, reached without following a link: a second name
/// for a link that points outside would be a way out.
static int make_hard_link(struct extraction *extraction, const char *target, int parent, const char *leaf) {
    char clean[PATH_MAX];
    if (safe_name(target, clean, sizeof(clean)) != NAME_USED) return ITEM_LEFT_OUT;
    const char *slash = strrchr(clean, '/');
    const char *target_leaf = slash == NULL ? clean : slash + 1;
    int folder = open_folder(extraction, clean, slash == NULL ? 0 : (size_t)(slash - clean), 0);
    if (folder < 0) return left_out_or(errno);
    int result = 0;
    struct stat first;
    struct stat second;
    if (fstatat(folder, target_leaf, &first, AT_SYMLINK_NOFOLLOW) != 0) {
        result = left_out_or(errno);
    } else if (!S_ISREG(first.st_mode)) {
        result = ITEM_LEFT_OUT;
    } else if (linkat(folder, target_leaf, parent, leaf, 0) != 0) {
        result = left_out_or(errno);
    } else if (fstatat(parent, leaf, &second, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(second.st_mode)
               || second.st_ino != first.st_ino) {
        // Something else took the file's place between the look and the link.
        unlinkat(parent, leaf, 0);
        result = ITEM_LEFT_OUT;
    }
    close(folder);
    return result;
}

/// Gives the folders the archive named their permissions and dates, the ones made last first, so that a folder is
/// still its owner's to write while the folders inside it get theirs.
static void finish_folders(struct extraction *extraction) {
    for (size_t index = extraction->count_folders; index > 0; index--) {
        const struct made_folder *folder = &extraction->folders[index - 1];
        if (!folder->given) continue;
        int fd = open_folder(extraction, folder->path, strlen(folder->path), 0);
        if (fd < 0) continue;
        struct stat stats;
        if (fstat(fd, &stats) == 0 && stats.st_ino == folder->inode) {
            fchmod(fd, folder->mode);
            set_times(fd, &folder->times);
        }
        close(fd);
    }
}

/// Moves past the data of an item left out, watching for a stop: 0, ECANCELED, or the reader's failure. libarchive
/// would pass over it at the next header without a look at the stop, and where the archive is compressed as a whole
/// (a .tar.gz) or in blocks of several items (7z, RAR) passing over means reading it all through. Of a zip, a xar
/// and a tar compressed in no other way it only moves on in the file, and is left to.
static int pass_over(ft_archive_control *control, struct archive *reader) {
    int format = archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK;
    if (archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE
        && (format == ARCHIVE_FORMAT_ZIP || format == ARCHIVE_FORMAT_XAR || format == ARCHIVE_FORMAT_TAR)) {
        return 0;
    }
    const void *block;
    size_t length;
    la_int64_t offset;
    int status;
    while ((status = archive_read_data_block(reader, &block, &length, &offset)) == ARCHIVE_OK) {
        if (is_stopped(control)) return ECANCELED;
        if (control != NULL) atomic_store(&control->done, archive_filter_bytes(reader, -1));
    }
    return status == ARCHIVE_EOF || status >= ARCHIVE_WARN ? 0 : reader_error(reader);
}

/// Whether the destination's disk keeps no extended attributes: it refuses the quarantine as something it doesn't
/// do (ENOTSUP), not as something its rules forbid.
static int keeps_no_attributes(const struct extraction *extraction, ft_archive_control *control) {
    if (control != NULL && atomic_load(&control->no_attributes)) return 1;
    return fsetxattr(extraction->root, quarantine_name, extraction->quarantine, extraction->quarantine_length, 0, 0)
               != 0
        && errno == ENOTSUP;
}

/// The open archive's quarantine, in a buffer the caller frees: 0, with nothing when it has none, or
/// FT_ARCHIVE_NOT_QUARANTINED when it can't be read, as what came out of a downloaded archive would then be run
/// unchecked.
static int read_quarantine(int fd, char **value, size_t *length) {
    *value = NULL;
    *length = 0;
    // It may grow between the look at its length and the read: it is read again then.
    for (int attempt = 0; attempt < 4; attempt++) {
        ssize_t size = fgetxattr(fd, quarantine_name, NULL, 0, 0, 0);
        if (size < 0) return errno == ENOATTR || errno == ENOTSUP ? 0 : FT_ARCHIVE_NOT_QUARANTINED;
        if (size == 0) return 0;
        char *buffer = malloc((size_t)size);
        if (buffer == NULL) return ENOMEM;
        ssize_t got = fgetxattr(fd, quarantine_name, buffer, (size_t)size, 0, 0);
        if (got > 0) {
            *value = buffer;
            *length = (size_t)got;
            return 0;
        }
        int error = got < 0 ? errno : ENOATTR;
        free(buffer);
        if (error == ENOATTR) return 0;
        if (error != ERANGE) return FT_ARCHIVE_NOT_QUARANTINED;
    }
    return FT_ARCHIVE_NOT_QUARANTINED;
}

int ft_archive_extract(
    const char *archive, const char *destination, const char *raw_name, int quarantine, ft_archive_control *control) {
    int fd = open(archive, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return errno;
    struct stat stats;
    if (fstat(fd, &stats) != 0) {
        int error = errno;
        close(fd);
        return error;
    }
    if (control != NULL) atomic_store(&control->total, (int64_t)stats.st_size);

    char *quarantine_value = NULL;
    size_t quarantine_length = 0;
    int result = quarantine ? read_quarantine(fd, &quarantine_value, &quarantine_length) : 0;
    if (result != 0) {
        close(fd);
        return result;
    }

    struct extraction extraction;
    memset(&extraction, 0, sizeof(extraction));
    extraction.control = control;
    extraction.quarantine = quarantine_value;
    extraction.quarantine_length = quarantine_length;
    extraction.parent_fd = -1;
    extraction.scratch = -1;
    if (quarantine_length > 0) extraction.quarantine_check = malloc(quarantine_length + 1);
    extraction.root = open(destination, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (extraction.root < 0 || (quarantine_length > 0 && extraction.quarantine_check == NULL)) {
        int error = extraction.root < 0 ? errno : ENOMEM;
        if (extraction.root >= 0) close(extraction.root);
        free(extraction.quarantine_check);
        free(quarantine_value);
        close(fd);
        return error;
    }
    // A disk that keeps no extended attributes at all (some network servers) takes the quarantine nowhere: what
    // comes out goes without it, as Finder copies onto such a disk. That is decided once, by the folder the items
    // are handed over in, before anything of the archive is read: no item can claim it for itself, and one that
    // refuses the quarantine on a disk that keeps it fails the archive.
    if (quarantine_length > 0 && keeps_no_attributes(&extraction, control)) {
        extraction.quarantine_length = 0;
    } else {
        // The destination too: with several items at its top, it is the folder they are handed over in.
        result = quarantine_item(&extraction, extraction.root);
    }

    // When the destination refused the quarantine, nothing is read.
    struct archive *reader = result == 0 ? new_reader(raw_name != NULL) : NULL;
    if (result == 0) {
        if (reader == NULL) {
            result = ENOMEM;
        } else if (archive_read_open_fd(reader, fd, 1 << 16) != ARCHIVE_OK) {
            result = reader_error(reader);
        } else if (raw_name != NULL && archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE) {
            // A file that isn't compressed at all: "raw" would copy it as it is.
            result = FT_ARCHIVE_UNREADABLE;
        }
    }

    char name[PATH_MAX];
    int64_t count_made = 0;
    while (result == 0) {
        struct archive_entry *entry;
        int status = archive_read_next_header(reader, &entry);
        if (status == ARCHIVE_EOF) break;
        if (status < ARCHIVE_WARN) {
            result = reader_error(reader);
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
        const char *given = raw_name;
        if (given == NULL) given = archive_entry_pathname(entry);
        if (given == NULL) given = archive_entry_pathname_utf8(entry);
        int named = given == NULL ? NAME_REFUSED : safe_name(given, name, sizeof(name));
        if (named == NAME_NOTHING) continue;
        if (named == NAME_REFUSED) {
            COUNT(control, skipped, 1);
            result = pass_over(control, reader);
            continue;
        }
        const char *leaf;
        int parent = parent_of(&extraction, name, &leaf);
        int made;
        if (parent < 0) {
            made = left_out_or(errno);
        } else if (archive_entry_hardlink(entry) != NULL) {
            made = make_hard_link(&extraction, archive_entry_hardlink(entry), parent, leaf);
        } else {
            switch (archive_entry_filetype(entry)) {
            case AE_IFREG: made = make_file(&extraction, reader, entry, parent, leaf); break;
            case AE_IFDIR: made = make_folder(&extraction, entry, parent, leaf, name); break;
            case AE_IFLNK: made = make_symlink(&extraction, entry, parent, leaf); break;
            // A pipe, a socket or a device: nothing kept in a folder, and making one may not be allowed.
            default: made = ITEM_LEFT_OUT; break;
            }
        }
        if (made == ITEM_LEFT_OUT) {
            COUNT(control, skipped, 1);
            result = pass_over(control, reader);
            continue;
        }
        if (made != 0) {
            result = made;
            break;
        }
        count_made++;
        COUNT(control, items, 1);
        if (control != NULL) atomic_store(&control->done, archive_filter_bytes(reader, -1));
    }
    // An item without the quarantine fails the whole archive, whatever its failure was taken for on the way.
    if (extraction.unquarantined) result = FT_ARCHIVE_NOT_QUARANTINED;
    // After a failure the folders stay their owner's to write, for what was made to be cleared away.
    if (result == 0) finish_folders(&extraction);
    if (result == 0 && count_made == 0) result = FT_ARCHIVE_EMPTY;

    for (size_t index = 0; index < extraction.count_folders; index++) free(extraction.folders[index].path);
    free(extraction.folders);
    free(extraction.slots);
    if (extraction.parent_fd >= 0) close(extraction.parent_fd);
    if (extraction.scratch >= 0) close(extraction.scratch);
    free(extraction.quarantine_check);
    free(quarantine_value);
    close(extraction.root);
    if (reader != NULL) archive_read_free(reader);
    close(fd);
    return result;
}

// MARK: Compress

/// Adds to `total` the bytes of the regular files under `path` that go into the zip: links not followed, and a disk
/// mounted inside not gone into, as compress_item walks them. 0, or ECANCELED when stopped.
static int add_data_bytes(const char *path, ft_archive_control *control, int64_t *total) {
    char *const roots[] = {(char *)path, NULL};
    FTS *tree = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (tree == NULL) return 0;
    int result = 0;
    FTSENT *node;
    while ((node = fts_read(tree)) != NULL) {
        if (is_stopped(control)) {
            result = ECANCELED;
            break;
        }
        if (node->fts_info == FTS_F && node->fts_statp != NULL) *total += (int64_t)node->fts_statp->st_size;
    }
    fts_close(tree);
    return result;
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
static int archive_error(struct archive *archive) {
    int error = archive_errno(archive);
    return error > 0 ? error : EIO;
}

/// Writes the regular file `source` as the data of the entry just started; ECANCELED when stopped.
static int write_file_data(struct archive *writer, const char *source, ft_archive_control *control) {
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
            result = archive_error(writer);
            break;
        }
        COUNT(control, done, count_read);
    }
    free(buffer);
    close(fd);
    return result;
}

/// Adds the item `full` and everything in it, named from `prefix_length` on. `disk` reads each item's metadata.
///
/// The folders are walked here, by full paths, and not by libarchive, whose own walk makes each folder the process's
/// working directory while it reads it: another thread's relative path would then mean something else.
static int compress_item(
    struct archive *writer, struct archive *disk, const char *full, size_t prefix_length,
    ft_archive_control *control) {
    char *const roots[] = {(char *)full, NULL};
    // Links stay links, and a disk mounted inside is not gone into.
    FTS *tree = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (tree == NULL) return errno;
    struct archive_entry *entry = archive_entry_new();
    struct archive_entry *sidecar = archive_entry_new();
    int result = entry == NULL || sidecar == NULL ? ENOMEM : 0;
    char relative[PATH_MAX + 1];
    char sidecar_path[PATH_MAX + 16];
    while (result == 0) {
        errno = 0;
        FTSENT *node = fts_read(tree);
        if (node == NULL) {
            result = errno;
            break;
        }
        if (is_stopped(control)) {
            result = ECANCELED;
            break;
        }
        mode_t type;
        switch (node->fts_info) {
        case FTS_D: type = AE_IFDIR; break;
        case FTS_F: type = AE_IFREG; break;
        case FTS_SL:
        case FTS_SLNONE: type = AE_IFLNK; break;
        // A folder again, on the way out of it.
        case FTS_DP: continue;
        // A pipe, a socket or a device: a zip can't hold it.
        case FTS_DEFAULT:
            COUNT(control, skipped, 1);
            continue;
        // A folder that can't be read, an item that can't be looked at.
        default:
            result = node->fts_errno > 0 ? node->fts_errno : EIO;
            continue;
        }
        const char *path = node->fts_path;
        if (strlen(path) <= prefix_length) {
            result = EINVAL;
            break;
        }
        archive_entry_clear(entry);
        archive_entry_copy_pathname(entry, path);
        archive_entry_copy_sourcepath(entry, path);
        if (archive_read_disk_entry_from_file(disk, entry, -1, node->fts_statp) < ARCHIVE_WARN) {
            result = archive_error(disk);
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
        time_t modified = archive_entry_mtime(entry);
        archive_entry_copy_pathname(entry, relative);
        if (archive_write_header(writer, entry) < ARCHIVE_WARN) {
            result = archive_error(writer);
        } else if (type == AE_IFREG && archive_entry_size(entry) > 0) {
            result = write_file_data(writer, path, control);
        }
        if (result == 0 && archive_write_finish_entry(writer) < ARCHIVE_WARN) result = archive_error(writer);
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
                result = archive_error(writer);
            }
        }
        free(metadata_copy);
    }
    if (sidecar != NULL) archive_entry_free(sidecar);
    if (entry != NULL) archive_entry_free(entry);
    fts_close(tree);
    return result;
}

int ft_archive_compress_zip(
    const char *base, const char *const *names, size_t count_names, const char *destination,
    ft_archive_control *control) {
    if (count_names == 0 || base == NULL || base[0] == '\0') return EINVAL;
    // The folder without the slashes it may end in, so that an item's name in the zip starts after exactly one:
    // "/" itself is left with nothing.
    char folder[PATH_MAX];
    size_t folder_length = strlen(base);
    while (folder_length > 0 && base[folder_length - 1] == '/') folder_length--;
    if (folder_length >= sizeof(folder)) return ENAMETOOLONG;
    memcpy(folder, base, folder_length);
    folder[folder_length] = '\0';
    char full[PATH_MAX * 2];
    // The total is counted first, for the progress to have one from the start: a walk of the folders alone, which
    // also brings what they hold into memory for the walk that writes the zip.
    int64_t total = 0;
    for (size_t index = 0; index < count_names; index++) {
        if (!join(folder, names[index], full, sizeof(full))) return ENAMETOOLONG;
        int counted = add_data_bytes(full, control, &total);
        if (counted != 0) return counted;
    }
    if (control != NULL) atomic_store(&control->total, total);

    int fd = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) return errno;
    struct archive *writer = archive_write_new();
    struct archive *disk = archive_read_disk_new();
    if (writer == NULL || disk == NULL) {
        if (writer != NULL) archive_write_free(writer);
        if (disk != NULL) archive_read_free(disk);
        close(fd);
        return ENOMEM;
    }
    // Each item's extended attributes and resource fork as copyfile packs them, and a link as a link.
    archive_read_disk_set_behavior(disk, ARCHIVE_READDISK_MAC_COPYFILE);
    archive_read_disk_set_symlink_physical(disk);
    archive_write_set_format_zip(writer);
    // Names as UTF-8, marked so: Windows reads them right, as Finder's zips don't let it.
    archive_write_set_options(writer, "zip:hdrcharset=UTF-8");
    int result = 0;
    if (archive_write_open_fd(writer, fd) != ARCHIVE_OK) result = archive_error(writer);
    for (size_t index = 0; result == 0 && index < count_names; index++) {
        join(folder, names[index], full, sizeof(full));
        result = compress_item(writer, disk, full, folder_length + 1, control);
    }
    archive_read_free(disk);
    // The zip's directory is written on close; a full disk may only show then.
    if (archive_write_close(writer) < ARCHIVE_WARN && result == 0) result = archive_error(writer);
    archive_write_free(writer);
    if (close(fd) != 0 && result == 0) result = errno;
    return result;
}
