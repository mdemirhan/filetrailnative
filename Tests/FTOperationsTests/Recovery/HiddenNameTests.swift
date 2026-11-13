// The checks recovery makes before it touches an item: only names this app gives what it hides are moved or removed
import Testing

@testable import FTOperations

struct HiddenNameTests {
    // A Replace's hidden item: a dot, the name, ".filetrail-" and 8 lowercase hex digits. Anything else may be the
    // user's own file, however close.
    @Test(arguments: [
        (".a.txt.filetrail-0000abcd", true), (".x.filetrail-0a1b2c3d", true), ("..filetrail-00000000", true),
        (".a.txt.filetrail-000abcd", false), (".a.txt.filetrail-00000abcd0", false),
        (".a.txt.filetrail-0000ABCD", false), ("a.txt.filetrail-0000abcd", false), ("x.filetrail-0000000g", false),
        (".x.filetrail-0000000g", false), (".a.txt-filetrail-0000abcd", false), (".filetrail-0000abcd", false),
        (".a.txt.filetrail-0000abcd ", false), ("", false),
    ])
    func aReplacesHiddenNameIsTheAppsOnly(name: String, isStaging: Bool) {
        #expect(isStagingName(name) == isStaging)
    }

    // A rename of several hides an item under ".filetrail-rename-" and 12 lowercase hex digits.
    @Test(arguments: [
        (".filetrail-rename-0a1b2c3d4e5f", true), (".filetrail-rename-0a1b2c3d4e5", false),
        (".filetrail-rename-0a1b2c3d4e5f6", false), (".filetrail-rename-0A1B2C3D4E5F", false),
        ("filetrail-rename-0a1b2c3d4e5f", false), ("x.filetrail-rename-0a1b2c3d4e5f", false),
        (".filetrail-rename-0a1b2c3d4e5g", false), (".filetrail-rename-", false),
    ])
    func aRenamesHiddenNameIsTheAppsOnly(name: String, isTemporary: Bool) {
        #expect(BatchRenameExecution.isTemporaryName(name) == isTemporary)
    }
}
