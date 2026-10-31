// Port of buildFdSearchArgs (packages/core/src/search/fdSearch.ts)
import Foundation

public enum FdSearchArgs {
    /// The `fd` argument list for a search; case sensitivity is fd's own smart case, so no flag is passed.
    public static func build(_ request: SearchRequest) -> [String] {
        // Files and folders. Symbolic links are left out, as they always have been.
        var args = ["--type", "f", "--type", "d", "--print0", "--absolute-path", "--color", "never"]

        // fd leaves out what Git ignores (.gitignore, .ignore, .fdignore and the global ignore file, inside Git
        // repositories) unless told otherwise.
        if !request.skipGitIgnored {
            args.append("--no-ignore")
        }
        // `.git` is not covered by ignore files: fd only passes over it for being hidden, so it would be searched as
        // soon as hidden files are included.
        if request.skipGitFolders {
            args += ["--exclude", ".git"]
        }

        // Macintosh HD is the startup disk alone, as in Finder: other disks, mounted at /Volumes, are searched from
        // their own top. (A leading "/" matches only at the search's top, and --one-file-system would also leave out
        // /Users and /Applications, on another APFS volume.)
        if request.rootPath == "/" {
            args += ["--exclude", "/Volumes"]
        }

        switch request.patternMode {
        case .glob:
            args.append("--glob")
        case .text:
            // The query is the text to find, not a pattern: "c++" and "report (1)" match as typed.
            args.append("--fixed-strings")
        case .regex:
            break
        }
        if request.matchScope == .path {
            args.append("--full-path")
        }
        if !request.recursive {
            args += ["--max-depth", "1"]
        }
        if request.includeHidden {
            args.append("--hidden")
        }

        // "--" ends option parsing so a query starting with "-" (e.g. "-xrm") is treated as a pattern, never as an fd
        // flag such as --exec.
        args += ["--", request.query, request.rootPath]
        return args
    }
}
