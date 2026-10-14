// Reads a folder with getattrlistbulk(2), the call the folder-size walk of the original uses
// (packages/native-fs/src/native_foldersize.c), asking for what a listing shows besides the name.
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

#include "CFileTrail.h"

#define BULK_BUFFER_SIZE (256 * 1024)

static int grow_entries(FTDirListing *listing, size_t *capacity) {
    if (listing->count < *capacity) {
        return 0;
    }
    size_t next = *capacity == 0 ? 256 : *capacity * 2;
    FTDirEntry *entries = realloc(listing->entries, next * sizeof(FTDirEntry));
    if (!entries) {
        return ENOMEM;
    }
    listing->entries = entries;
    *capacity = next;
    return 0;
}

static int grow_names(FTDirListing *listing, size_t *capacity, size_t needed) {
    if (listing->names_length + needed <= *capacity) {
        return 0;
    }
    size_t next = *capacity == 0 ? 8192 : *capacity;
    while (next < listing->names_length + needed) {
        next *= 2;
    }
    char *names = realloc(listing->names, next);
    if (!names) {
        return ENOMEM;
    }
    listing->names = names;
    *capacity = next;
    return 0;
}

int ft_read_directory(const char *path, FTDirListing *listing) {
    memset(listing, 0, sizeof(*listing));
    int fd = open(path, O_RDONLY | O_DIRECTORY);
    if (fd < 0) {
        return errno;
    }
    char *buffer = malloc(BULK_BUFFER_SIZE);
    if (!buffer) {
        close(fd);
        return ENOMEM;
    }
    struct attrlist request;
    memset(&request, 0, sizeof(request));
    request.bitmapcount = ATTR_BIT_MAP_COUNT;
    request.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE |
                         ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCESSMASK;
    request.fileattr = ATTR_FILE_DATALENGTH;

    size_t entry_capacity = 0;
    size_t name_capacity = 0;
    int result = 0;
    for (;;) {
        int count = getattrlistbulk(fd, &request, buffer, BULK_BUFFER_SIZE, FSOPT_PACK_INVAL_ATTRS);
        if (count < 0) {
            result = errno;
            break;
        }
        if (count == 0) {
            break;
        }
        char *cursor = buffer;
        for (int index = 0; index < count; index++) {
            char *record = cursor;
            uint32_t record_length = *(uint32_t *)record;
            cursor += record_length;

            char *field = record + sizeof(uint32_t);
            attribute_set_t returned = *(attribute_set_t *)field;
            field += sizeof(attribute_set_t);
            // An entry the disk could not describe carries an error, packed first.
            if (returned.commonattr & ATTR_CMN_ERROR) {
                uint32_t error = *(uint32_t *)field;
                field += sizeof(uint32_t);
                if (error != 0) {
                    continue;
                }
            }
            if (!(returned.commonattr & ATTR_CMN_NAME)) {
                continue;
            }
            attrreference_t *name_reference = (attrreference_t *)field;
            char *name = field + name_reference->attr_dataoffset;
            field += sizeof(attrreference_t);
            uint32_t length = name_reference->attr_length;
            if (length > 0) {
                length -= 1; // the terminating NUL
            }
            if (length == 0 || (length == 1 && name[0] == '.') || (length == 2 && name[0] == '.' && name[1] == '.')) {
                continue;
            }

            FTDirEntry entry;
            memset(&entry, 0, sizeof(entry));
            if (returned.commonattr & ATTR_CMN_OBJTYPE) {
                fsobj_type_t type = *(fsobj_type_t *)field;
                field += sizeof(fsobj_type_t);
                entry.type = type == VDIR ? FT_ENTRY_DIRECTORY
                             : type == VREG ? FT_ENTRY_FILE
                             : type == VLNK ? FT_ENTRY_SYMLINK
                                            : FT_ENTRY_OTHER;
            }
            if (returned.commonattr & ATTR_CMN_CRTIME) {
                struct timespec time = *(struct timespec *)field;
                field += sizeof(struct timespec);
                entry.crtime_sec = time.tv_sec;
                entry.crtime_nsec = (int32_t)time.tv_nsec;
                entry.crtime_valid = 1;
            }
            if (returned.commonattr & ATTR_CMN_MODTIME) {
                struct timespec time = *(struct timespec *)field;
                field += sizeof(struct timespec);
                entry.mtime_sec = time.tv_sec;
                entry.mtime_nsec = (int32_t)time.tv_nsec;
                entry.mtime_valid = 1;
            }
            if (returned.commonattr & ATTR_CMN_ACCESSMASK) {
                entry.mode = *(uint32_t *)field;
                field += sizeof(uint32_t);
            }
            if (entry.type != FT_ENTRY_DIRECTORY && (returned.fileattr & ATTR_FILE_DATALENGTH)) {
                entry.size = *(off_t *)field;
                field += sizeof(off_t);
            }

            if ((result = grow_entries(listing, &entry_capacity)) != 0 ||
                (result = grow_names(listing, &name_capacity, length)) != 0) {
                goto done;
            }
            entry.name_offset = (uint32_t)listing->names_length;
            entry.name_length = length;
            memcpy(listing->names + listing->names_length, name, length);
            listing->names_length += length;
            listing->entries[listing->count++] = entry;
        }
    }
done:
    free(buffer);
    close(fd);
    if (result != 0) {
        ft_free_listing(listing);
    }
    return result;
}

void ft_free_listing(FTDirListing *listing) {
    free(listing->entries);
    free(listing->names);
    memset(listing, 0, sizeof(*listing));
}
