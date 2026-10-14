#ifndef CFILETRAIL_H
#define CFILETRAIL_H

#include <stddef.h>
#include <stdint.h>

/// Placeholder so the target builds; later work packages add the real C code.
int ft_c_version(void);

/// What an entry of a folder is (the object type getattrlistbulk reports).
typedef enum {
    FT_ENTRY_OTHER = 0,
    FT_ENTRY_DIRECTORY = 1,
    FT_ENTRY_FILE = 2,
    FT_ENTRY_SYMLINK = 3,
} FTEntryType;

/// One entry of a folder, as `lstat` would describe it. Times are Unix times; a time the disk doesn't
/// keep has `*_valid` 0. `name_offset` and `name_length` locate the UTF-8 name in `FTDirListing.names`.
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
} FTDirEntry;

typedef struct {
    FTDirEntry *entries;
    size_t count;
    char *names;
    size_t names_length;
} FTDirListing;

/// Reads a folder with getattrlistbulk(2): every name with its type, size, times and permissions in a
/// few calls. Returns 0, or an errno. `.` and `..` are left out. Free the result with ft_free_listing.
int ft_read_directory(const char *path, FTDirListing *listing);
void ft_free_listing(FTDirListing *listing);

#endif
