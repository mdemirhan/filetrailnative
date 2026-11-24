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

    @Test func xcodeAndPackageFilesHaveTheirLanguages() {
        #expect(TextLanguage.detect(fileName: "Base.xcconfig").id == "xcconfig")
        #expect(TextLanguage.detect(fileName: "project.pbxproj").id == "pbxproj")
        #expect(TextLanguage.detect(fileName: "Localizable.strings").id == "strings")
        #expect(TextLanguage.detect(fileName: "Localizable.xcstrings").id == "json")
        #expect(TextLanguage.detect(fileName: "module.modulemap").id == "modulemap")
        #expect(TextLanguage.detect(fileName: "App.xcscheme").id == "xml")
        #expect(TextLanguage.detect(fileName: "Package.resolved").id == "json")
        #expect(TextLanguage.detect(fileName: "Shaders.metal").id == "metal")
        #expect(TextLanguage.detect(fileName: "Appfile").id == "ruby")
        #expect(TextLanguage.detect(fileName: "events.jsonl").id == "json")
        #expect(TextLanguage.detect(fileName: "uv.lock").id == "toml")
        #expect(TextLanguage.detect(fileName: "flake.lock").id == "json")
        #expect(TextLanguage.detect(fileName: "Podfile.lock").id == "yaml")
        #expect(TextLanguage.detect(fileName: "go.mod").id == "gomod")
        #expect(TextLanguage.detect(fileName: ".htaccess").id == "apache")
        #expect(TextLanguage.detect(fileName: "Justfile").id == "makefile")
        #expect(TextLanguage.detect(fileName: "page.erb").id == "html")
        #expect(TextLanguage.detect(fileName: "report.Rmd").id == "markdown")
    }

    @Test func aHashBangLineNamesItsProgramAfterEnvAndItsOptions() {
        func language(_ line: String) -> String { TextLanguage.detect(fileName: "script", firstLine: line).id }
        #expect(language("#!/usr/bin/env -S uv run --script") == "python")
        #expect(language("#!/usr/bin/env -S deno run --allow-net") == "javascript")
        #expect(language("#!/usr/bin/env -S npx tsx") == "typescript")
        #expect(language("#!/usr/bin/env Rscript") == "r")
        #expect(language("#!/usr/bin/osascript") == "applescript")
        #expect(language("#! /bin/bash -e") == "shell")
        #expect(language("#!/usr/bin/env python3.12") == "python")
        #expect(language("#!/usr/bin/env nothing-known") == "plain")
    }

    @Test func aNameWithoutAnExtensionGoesByItsHashBangLineFirst() {
        #expect(TextLanguage.detect(fileName: "BUILD").id == "starlark")
        #expect(TextLanguage.detect(fileName: "BUILD", firstLine: "#!/bin/sh").id == "shell")
        #expect(TextLanguage.detect(fileName: "MODULE.bazel").id == "starlark")
        // A name with an extension keeps it over the `#!` line.
        #expect(TextLanguage.detect(fileName: "tool.rb", firstLine: "#!/bin/sh").id == "ruby")
    }

    @Test func everyLanguageHasItsOwnIDAndPlainTextComesFirst() {
        let ids = TextLanguage.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == "plain")
        #expect(TextLanguage.all.count >= 75)
        let names = TextLanguage.all.dropFirst().map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func onlyMarkdownHasAPreview() {
        #expect(TextLanguage.all.filter(\.hasPreview).map(\.id) == ["markdown"])
    }
}
