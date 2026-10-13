// The Swift side of selftest.sh: prints FTTestSupport.TreeSnapshot's JSON for a folder.
// Built by selftest.sh with swiftc together with Tests/FTTestSupport/{TreeSnapshot,JSONText}.swift.
import Foundation

@main
struct SnapshotMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: tree-snapshot <root>\n".utf8))
            exit(2)
        }
        do {
            print(TreeSnapshot.json(try TreeSnapshot.entries(of: arguments[1])), terminator: "")
        } catch {
            FileHandle.standardError.write(Data("tree-snapshot: \(error)\n".utf8))
            exit(1)
        }
    }
}
