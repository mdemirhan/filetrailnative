// Interface to bunzip.c: one bzip2 stream decompressed into a buffer, with the system's libbz2.
#ifndef FT_BUNZIP_H
#define FT_BUNZIP_H

#include <stddef.h>

/// Decompresses the bzip2 stream `source` (`sourceLength` bytes) into `destination`, which has room for
/// `*destinationLength` bytes; on success sets `*destinationLength` to what was written and returns 0. Anything else
/// (damaged data, more than the room) returns -1.
int ft_bunzip2(const void *source, size_t sourceLength, void *destination, size_t *destinationLength);

#endif
