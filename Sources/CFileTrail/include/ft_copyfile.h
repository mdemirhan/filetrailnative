// Interface to copyfile.c, the copyfile(3) calls of the write engine (a port of
// packages/native-fs/src/native_copyfile.c).
#ifndef FT_COPYFILE_H
#define FT_COPYFILE_H

#include <stdint.h>

/// The stop flag of one copy and the bytes of data it has copied so far, shared between the thread
/// that runs the copy and the threads that stop it or read its progress.
typedef struct ft_copy_control ft_copy_control;

/// A cleared control; NULL when out of memory. Free it with ft_copy_control_free once the copy returned.
ft_copy_control *ft_copy_control_create(void);
void ft_copy_control_free(ft_copy_control *control);

/// Asks the copy to stop: it quits at its next chunk of data with ECANCELED, or doesn't start.
void ft_copy_control_stop(ft_copy_control *control);
int ft_copy_control_is_stopped(const ft_copy_control *control);

/// The bytes of the file's data copied so far (COPYFILE_STATE_COPIED), 0 for a clone.
int64_t ft_copy_control_copied(const ft_copy_control *control);
void ft_copy_control_set_copied(ft_copy_control *control, int64_t copied);

/// `nativeCopyFile`: copyfile(3) with COPYFILE_ALL | CLONE | NOFOLLOW_SRC | EXCL | DATA_SPARSE. Without a
/// control the copy has no status callback and can't be stopped part way. Returns 0, or the errno:
/// ECANCELED when stopped (or stopped before it began), the write's own errno when the resource fork
/// couldn't be written.
int ft_copyfile(const char *source, const char *destination, ft_copy_control *control);

/// `nativeCopyMetadata`: copyfile(3) with COPYFILE_METADATA | NOFOLLOW_SRC, a folder's own metadata onto a
/// folder that already exists. Returns 0 or the errno.
int ft_copy_metadata(const char *source, const char *destination);

#endif
