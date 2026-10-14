// The differential's execution cases that need Replace (executeReplace, P3-04's): until it is ported they are left
// out of ExecGoldenTests. P3-04 empties this list.
enum PendingReplace {
    static let cases: Set<String> = [
        // exec-copy
        "file conflict replaced: the old file goes to the Trash",
        "folder conflict merged with files inside replaced",
        "folder conflict replaced: the old folder and its own items go to the Trash",
        "type mismatch: a file replaces a folder",
        "type mismatch: a folder replaces a file",
        "package conflict replaced whole, never merged",
        "Replace on a disk without a Trash, deleted for good once agreed",
        "Replace on a disk without a Trash, skipped: nothing changes",
        "symlink conflict replaced by the link itself",
        "folder replaced on an HFS+ disk",
        "Replace on another disk without a Trash, deleted for good once agreed",
        "Replace on a FAT32 disk without a Trash, skipped: nothing changes",
        "Replace on a disk without a Trash, deleted for good for the rest: the second isn't asked",
        "a locked item on another disk can't go to the Trash: the Replace fails, saying it is locked",
        // exec-cut
        "cut with Replace on the same disk: the old file to the Trash, the source moved in",
        "cut a folder replacing a folder on the same disk",
        "cut a folder merged into a folder: moved file by file, emptied folders removed",
        "cut a folder to another disk with Replace",
        // exec-runtime
        "a file appears where a file is pasted, answered overwrite",
        "a folder appears where a folder is pasted, answered overwrite",
        "the file to replace is changed after the review, answered overwrite",
        "a file appears in a merged folder part way through, answered overwrite",
        "a moved file whose name is taken after the review, answered overwrite",
        "Merge for the rest, then a file inside: a file is asked about",
    ]
}
