# The check that no new path is read back from a file URL, for scripts/ci.sh.
#
# A path is kept as the disk spells it, and paths are compared byte for byte (docs/decisions/must-stay.md, "Byte-exact
# path comparison"). `URL(fileURLWithPath:)`, `standardizedFileURL` and `resolvingSymlinksInPath()` give an accent
# decomposed whatever the disk stores, so a path read from such a URL no longer matches the rows of a listing.
#
# This reads text, not types: it finds the readbacks that can be told from how a line is written, and nothing else. A
# `.path` on a URL held under a plain name (`home.path`, `file.path`) passes unseen, as a struct's `.path` must.

# What is found, in the lines of Swift sources that aren't comments:
#   a URL made and read on one line           URL(fileURLWithPath: x).path, URL(filePath: x)….path
#   a URL's own tidying, then its path        ….standardizedFileURL.path, ….resolvingSymlinksInPath().path
#   a path component added or taken, then it  ….appendingPathComponent("a").path, ….deletingLastPathComponent().path
#   the system's folders                      homeDirectoryForCurrentUser.path, temporaryDirectory.path
#   anything named as a URL                   url.path, fileURL?.path, urls.first?.path, urls.map(\.path)
#   the app's own URLs                        AppStatePaths.…(…).path, currentFolder.path, selectedContentFolder?.path,
#                                             userData.path, and `comparablePath`, a URL's path for comparing
PATH_READBACKS='URL\((fileURLWithPath|filePath):.*\)[?!]?\.(path|relativePath)\b'
PATH_READBACKS+='|(standardizedFileURL|standardized|absoluteURL|filePathURL|resolvingSymlinksInPath\(\))[?!]?\.(path|relativePath)\b'
PATH_READBACKS+='|(appendingPathComponent|appendingPathExtension|deletingLastPathComponent|deletingPathExtension)\(.*\)\.(path|relativePath)\b'
PATH_READBACKS+='|\b(homeDirectoryForCurrentUser|temporaryDirectory)\.(path|relativePath)\b'
PATH_READBACKS+='|\b[A-Za-z0-9_]*(url|URL|Url)s?\b[?!]?(\.[A-Za-z]+(\(\))?[?!]?)*\.(path|relativePath)\b'
PATH_READBACKS+='|\b[A-Za-z0-9_]*(urls|URLs|Urls)\b.*\\\.(path|relativePath)\b'
PATH_READBACKS+='|\bAppStatePaths\.[A-Za-z]+\(.*\)\.path\b'
PATH_READBACKS+='|\b(currentFolder|selectedFolder|selectedContentFolder|navigationTarget|userData|userDataDirectory)[?!]?\.path\b'
PATH_READBACKS+='|\.comparablePath\b'
# In FTAppKit a tab's and a pane's `folder` is a URL; in the other modules `folder` names structs with a path of their
# own. The lines are searched as grep gives them, `file:line:text`.
PATH_READBACKS+='|^[^:]*/FTAppKit/[^:]*:.*\bfolder[?!]?\.path\b'

# path_readbacks <sources folder> <allow-list>: fails, naming each, on a readback in the sources that the allow-list
# doesn't hold, and on a line of the allow-list the sources no longer have.
#
# The allow-list holds today's readbacks, one `path/to/File.swift: the line` each, the line without the spaces around
# it; `#` starts a comment. A line is known by its file and its text, not its number: one that moves, or has lines
# added above it, is the same line, and a second readback in the file is a new one, as is a line written twice that
# the list holds once. A line that changes is a new line: its readback is looked at again.
path_readbacks() {
    local sources="$1" allowed="$2" lines
    if [ ! -d "$sources" ] || [ ! -f "$allowed" ]; then
        echo "path_readbacks: needs the sources folder and the allow-list ($sources, $allowed)"
        return 2
    fi
    # The lines that read a path of anything first: the whole pattern over every line of the sources takes seconds.
    # Finding none is no failure of the check: what fails it is said below.
    lines="$(grep -rnE --include='*.swift' '\.(path|relativePath|comparablePath)\b' "$sources" |
        grep -E "$PATH_READBACKS" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | sort -t: -k1,1 -k2,2n)" || true
    printf '%s\n' "$lines" |
        awk -v allowed="$allowed" '
            function trimmed(text) { gsub(/^[ \t]+|[ \t]+$/, "", text); return text }
            BEGIN {
                while ((getline entry < allowed) > 0) {
                    at = index(entry, ": ")
                    if (entry ~ /^[ \t]*(#|$)/ || at == 0) continue
                    key = substr(entry, 1, at - 1) SUBSEP trimmed(substr(entry, at + 2))
                    if (!(key in listed)) order[++entries] = key
                    listed[key]++
                }
            }
            $0 != "" {
                colon = index($0, ":")
                file = substr($0, 1, colon - 1)
                rest = substr($0, colon + 1)
                colon = index(rest, ":")
                text = trimmed(substr(rest, colon + 1))
                if (++found[file SUBSEP text] > listed[file SUBSEP text]) {
                    print file ":" substr(rest, 1, colon - 1) ": a path read back from a URL: " text
                    fresh++
                }
            }
            END {
                for (i = 1; i <= entries; i++) {
                    key = order[i]
                    if (found[key] >= listed[key]) continue
                    split(key, part, SUBSEP)
                    print allowed ": " part[1] " no longer has this line: " part[2]
                    stale++
                }
                if (fresh) {
                    print "A path is kept as the disk spells it, a string from a listing or realpath, and never read back from a URL, which may give an accent decomposed whatever the disk stores (docs/decisions/must-stay.md, Byte-exact path comparison)."
                    print "Pass on the string the URL was made from, or a pane'"'"'s folderPath. Where a URL is all there is (a panel'"'"'s answer, a folder of the system'"'"'s), add the line to " allowed " with its reason."
                }
                if (stale) {
                    print "Take a line that is gone out of " allowed "; one that changed and still reads a path from a URL is listed again as it is now."
                }
                exit fresh || stale ? 1 : 0
            }'
}
