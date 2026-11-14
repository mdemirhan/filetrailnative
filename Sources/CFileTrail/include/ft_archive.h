// Interface to archive.c: archives taken apart and zips made with the system's libarchive.
#ifndef FT_ARCHIVE_H
#define FT_ARCHIVE_H

#include <stddef.h>
#include <stdint.h>

/// What went wrong besides an errno (which is returned as it is, positive).
enum {
    /// The file isn't an archive of a kind that is read, or it is damaged.
    FT_ARCHIVE_UNREADABLE = -1,
    /// An item in it is protected with a password.
    FT_ARCHIVE_NEEDS_PASSWORD = -2,
    /// It holds nothing to extract.
    FT_ARCHIVE_EMPTY = -3,
};

/// The stop flag of one archive's work and how far it has come, shared between the thread that does it and the
/// threads that stop it or read its progress.
typedef struct ft_archive_control ft_archive_control;

/// A cleared control; NULL when out of memory. Free it with ft_archive_control_free once the work returned.
ft_archive_control *ft_archive_control_create(void);
void ft_archive_control_free(ft_archive_control *control);

/// Asks the work to stop: it quits at its next block of data with ECANCELED.
void ft_archive_control_stop(ft_archive_control *control);

/// Bytes done so far: of the archive read, when extracting; of the items' data read, when compressing.
int64_t ft_archive_control_done(const ft_archive_control *control);
/// Bytes to do: the archive's size, or the items' data once they have been counted.
int64_t ft_archive_control_total(const ft_archive_control *control);
/// Items written so far.
int64_t ft_archive_control_items(const ft_archive_control *control);
/// Items of an archive left out: a name that would reach outside the folder (`/…`, `..`), a second item of a
/// name already written, or a kind a zip can't hold (a socket, a device).
int64_t ft_archive_control_skipped(const ft_archive_control *control);

/// Takes `archive` apart into `destination`, an empty folder that exists. Names that would reach outside it are
/// left out, so are `__MACOSX` and the resource forks and extended attributes it holds are put back on their items,
/// permissions lose their setuid, setgid and sticky bits, and nothing is replaced. When `quarantine` is set, every
/// item gets the archive's quarantine, so what came from the internet is checked as the archive would be.
/// `raw_name`, for a single compressed file (`.gz`, `.bz2`, `.xz` not holding a tar), is the name the file is
/// written as. Returns 0, an errno (ECANCELED when stopped), or one of the FT_ARCHIVE_ codes; `message` gets
/// libarchive's own words, for the log.
int ft_archive_extract(
    const char *archive, const char *destination, const char *raw_name, int quarantine,
    ft_archive_control *control, char *message, size_t message_size);

/// Makes the zip `destination` (which must not exist) of the items `names` of the folder `base`, as Finder's
/// Compress does: each item's extended attributes and resource fork go into `__MACOSX` as `._` files, names are
/// marked UTF-8, links stay links. Returns 0, an errno (ECANCELED when stopped), and leaves the zip partly written
/// when it fails: the caller removes it.
int ft_archive_compress_zip(
    const char *base, const char *const *names, size_t count, const char *destination,
    ft_archive_control *control, char *message, size_t message_size);

#endif
