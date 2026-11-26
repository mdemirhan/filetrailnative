#include "ft_bunzip.h"

#include <bzlib.h>
#include <limits.h>

int ft_bunzip2(const void *source, size_t sourceLength, void *destination, size_t *destinationLength) {
    if (sourceLength > UINT_MAX || *destinationLength > UINT_MAX) return -1;
    unsigned int length = (unsigned int)*destinationLength;
    int result = BZ2_bzBuffToBuffDecompress(destination, &length, (char *)source, (unsigned int)sourceLength, 0, 0);
    if (result != BZ_OK) return -1;
    *destinationLength = length;
    return 0;
}
