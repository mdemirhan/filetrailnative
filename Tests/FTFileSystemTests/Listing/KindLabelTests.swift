// The Kind a listing shows for a package: the system's words, as for a file, where it names the package
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct KindLabelTests {
    private let labeler = KindLabeler(describer: { path in
        path.hasSuffix(".key") ? "Keynote Presentation" : path.hasSuffix(".app") ? "Something else" : nil
    })

    @Test func aPackageIsCalledWhatTheSystemCallsIt() {
        #expect(labeler.label(for: .bundle, path: "/Users/demo/Slides.key") == "Keynote Presentation")
        // The packages the app names itself keep their names, and one the system has no words for is a bundle.
        #expect(labeler.label(for: .bundle, path: "/Applications/Safari.app") == "Application")
        #expect(labeler.label(for: .bundle, path: "/Users/demo/Thing.plugin") == "Bundle")
        #expect(KindLabeler(describer: nil).label(for: .bundle, path: "/Users/demo/Slides.key") == "Bundle")
    }
}
