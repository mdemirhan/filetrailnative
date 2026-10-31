#ifndef CFILETRAIL_H
#define CFILETRAIL_H

#include <stddef.h>
#include <stdint.h>
#include "ft_copyfile.h"
#include "ft_foldersize.h"

/// Placeholder so the target builds; later work packages add the real C code.
int ft_c_version(void);

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
    int32_t mode_valid;
    int32_t size_valid;
} FTDirEntry;

typedef struct {
    FTDirEntry *entries;
    size_t count;
    char *names;
    size_t names_length;
} FTDirListing;

/// What a folder read gives besides each entry's name and type; each costs the disk a little more.
enum {
    FT_READ_MODE = 1,     /* permissions */
    FT_READ_SIZE = 2,     /* the size of a file (not of a folder) */
    FT_READ_MODIFIED = 4, /* the modification time */
    FT_READ_CREATED = 8,  /* the creation time */
};

/// Reads a folder with getattrlistbulk(2): every name with its type, and the `attributes` asked for, in a
/// few calls. Returns 0, or an errno. `.` and `..` are left out. Free the result with ft_free_listing.
int ft_read_directory(const char *path, unsigned int attributes, FTDirListing *listing);
void ft_free_listing(FTDirListing *listing);

#endif
