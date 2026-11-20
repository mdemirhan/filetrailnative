import Foundation
import Testing

@testable import FTFoundation

@Suite struct TextLanguageTests {
    @Test func aFileIsMatchedByItsNameItsExtensionThenItsFirstLine() {
        #expect(TextLanguage.detect(fileName: "Makefile").id == "makefile")
        #expect(TextLanguage.detect(fileName: "Dockerfile").id == "dockerfile")
        #expect(TextLanguage.detect(fileName: "app.dockerfile").id == "dockerfile")
        #expect(TextLanguage.detect(fileName: ".zshrc").id == "shell")
        #expect(TextLanguage.detect(fileName: ".gitignore").id == "ignore")
        #expect(TextLanguage.detect(fileName: "CMakeLists.txt").id == "cmake")
        #expect(TextLanguage.detect(fileName: "View.SWIFT").id == "swift")
        #expect(TextLanguage.detect(fileName: "index.ts").id == "typescript")
        #expect(TextLanguage.detect(fileName: "ScopeFunctions.kt").id == "kotlin")
        #expect(TextLanguage.detect(fileName: "settings.yml").id == "yaml")
        #expect(TextLanguage.detect(fileName: ".env.local").id == "dotenv")
        #expect(TextLanguage.detect(fileName: "build", firstLine: "#!/usr/bin/env python3 -u").id == "python")
        #expect(TextLanguage.detect(fileName: "run", firstLine: "#!/bin/zsh").id == "shell")
        #expect(TextLanguage.detect(fileName: "notes").id == "plain")
        #expect(TextLanguage.detect(fileName: "notes.unknownext").id == "plain")
    }

    @Test func everyLanguageHasItsOwnIDAndPlainTextComesFirst() {
        let ids = TextLanguage.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == "plain")
        #expect(TextLanguage.all.count >= 55)
        let names = TextLanguage.all.dropFirst().map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func onlyMarkdownHasAPreview() {
        #expect(TextLanguage.all.filter(\.hasPreview).map(\.id) == ["markdown"])
    }
}
