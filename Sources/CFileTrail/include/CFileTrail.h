#ifndef CFILETRAIL_H
#define CFILETRAIL_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include "ft_archive.h"
#include "ft_copyfile.h"
#include "ft_foldersize.h"

/// What an entry of a folder is (the object type getattrlistbulk reports).
typedef enum {
    FT_ENTRY_OTHER = 0,
    FT_ENTRY_DIRECTORY = 1,
    FT_ENTRY_FILE = 2,
    FT_ENTRY_SYMLINK = 3,
} FTEntryType;

/// One entry of a folder, as `lstat` would describe it. Times are Unix times; what the disk didn't give
/// has `*_valid` 0. `name_offset` and `name_length` locate the UTF-8 name in `FTDirListing.names`.
typedef struct {
    uint32_t name_offset;
    uint32_t name_length;
    int32_t type;
    uint32_t mode;
    int64_t size;
    int64_t mtime_sec;
    int32_t mtime_nsec;
    int32_t mtime_valid;
    int64_t crtime_sec;
    int32_t crtime_nsec;
    int32_t crtime_valid;
    int64_t added_sec;
    int32_t added_nsec;
    int32_t added_valid;
    int32_t mode_valid;
    int32_t size_valid;
    int32_t has_custom_icon;
    int32_t finder_label;
    int32_t is_empty_folder;
    int32_t has_hidden_flag;
    int32_t is_alias;
    int32_t has_bundle_bit;
} FTDirEntry;

typedef struct {
    FTDirEntry *entries;
    size_t count;
    char *names;
    size_t names_length;
} FTDirListing;

/// What a folder read gives besides each entry's name and type; each costs the disk a little more.
enum {
    FT_READ_MODE = 1,         /* permissions */
    FT_READ_SIZE = 2,         /* the size of a file (not of a folder) */
    FT_READ_MODIFIED = 4,     /* the modification time */
    FT_READ_CREATED = 8,      /* the creation time */
    FT_READ_FINDER_INFO = 16, /* Finder's custom-icon, alias and package flags and label color */
    FT_READ_EMPTY_FOLDERS = 32, /* which folders hold nothing, on the disks that store a folder's count (APFS, HFS+) */
    FT_READ_HIDDEN_FLAG = 64, /* the flag that hides an item whatever its name (UF_HIDDEN) */
    FT_READ_ADDED = 128,      /* when the item was put in the folder (Date Added), on the disks that keep it */
};

/// Reads a folder with getattrlistbulk(2): every name with its type, and the `attributes` asked for, in a
/// few calls. Returns 0, or an errno. `.` and `..` are left out. Free the result with ft_free_listing.
int ft_read_directory(const char *path, unsigned int attributes, FTDirListing *listing);

/// Whether the disk of the open folder `fd` lists a name otherwise than it answers to it. FAT and exFAT list a name
/// with its accents decomposed. Asked about the one item (getattrlist, realpath, what a watch reports) they answer
/// with the spelling it was first looked up or made by since the disk was mounted, whichever that was, and some calls
/// find it only by that spelling (rename on FAT, unlink on exFAT). Whatever reads a folder there asks for each such
/// name with ft_held_name, so an item has one spelling in the app: the one its disk holds for it.
int ft_listing_respells_names(int fd);

/// Room for a name and its NUL.
#define FT_HELD_NAME_SIZE 1024

/// The name the disk holds for the item the open folder `fd` lists as `name`, a link not followed, into `held`
/// (`size` bytes, FT_HELD_NAME_SIZE is enough). An item not looked up since the disk was mounted is held from then on
/// by the spelling asked for here. Returns 0, or an errno: EXDEV for another disk mounted there, which is named after
/// the disk.
int ft_held_name(int fd, const char *name, char *held, size_t size);

/// ft_held_name for a folder whose device (`st_dev`) is known, so many names of one folder are asked without
/// reading it each time.
int ft_held_name_on(int fd, dev_t device, const char *name, char *held, size_t size);

/// Whether `name` (`length` bytes) has a byte outside ASCII: only such a name can be spelled two ways.
int ft_name_has_accent_bytes(const char *name, size_t length);

/// When the item at `path` (a link itself, not what it points to) was put in its folder. Returns 0, ENOATTR when the
/// disk doesn't keep it, or an errno.
int ft_added_time(const char *path, int64_t *seconds, int32_t *nanoseconds);
void ft_free_listing(FTDirListing *listing);

#endif
