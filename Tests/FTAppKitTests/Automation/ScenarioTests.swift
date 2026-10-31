#if DEBUG
    import FTFoundation
    import Foundation
    import Testing

    @testable import FTAppKit

    @Suite struct ScenarioTests {
        private func parse(_ json: String) throws -> Scenario {
            try Scenario.parse(Data(json.utf8))
        }

        @Test func readsEveryStep() throws {
            let scenario = try parse(
                """
                {
                  "name": "list-light", "description": "ignored", "root": "lighthouse/Lighthouse",
                  "now": "2026-10-13T14:38:00", "setup": { "emptyFolders": [] },
                  "steps": [
                    { "step": "window", "width": 1200, "height": 760 },
                    { "step": "prefs", "prefs": { "theme": "dark", "zoomPercent": 100, "foldersFirst": true } },
                    { "step": "open", "path": "app/src/components" },
                    { "step": "select", "names": ["a.txt", "b.txt"] },
                    { "step": "key", "key": "ArrowDown", "modifiers": ["cmd"] },
                    { "step": "key", "key": "Enter" },
                    { "step": "type", "text": "Trip" },
                    { "step": "command", "id": "goBack" },
                    { "step": "wait", "ms": 250 },
                    { "step": "snapshot", "name": "main" },
                    { "step": "geometry", "name": "main" },
                    { "step": "geometry", "name": "all", "allViews": true }
                  ]
                }
                """)
            #expect(scenario.name == "list-light")
            #expect(scenario.root == "lighthouse/Lighthouse")
            #expect(
                scenario.steps == [
                    .window(width: 1200, height: 760),
                    .prefs(["theme": .string("dark"), "zoomPercent": .number(100), "foldersFirst": .bool(true)]),
                    .open(path: "app/src/components"),
                    .select(names: ["a.txt", "b.txt"]),
                    .key(key: "ArrowDown", modifiers: ["cmd"]),
                    .key(key: "Enter", modifiers: []),
                    .type(text: "Trip"),
                    .command(id: "goBack"),
                    .wait(milliseconds: 250),
                    .snapshot(name: "main"),
                    .geometry(name: "main", allViews: false),
                    .geometry(name: "all", allViews: true),
                ])
            #expect(scenario.steps.map(\.kind).first == "window")
        }

        @Test func rejectsUnknownStepsAndMissingValues() {
            #expect(throws: Scenario.ParseError.self) { try parse(#"{"name": "x", "steps": [{"step": "fly"}]}"#) }
            #expect(throws: Scenario.ParseError.self) { try parse(#"{"name": "x", "steps": [{"step": "open"}]}"#) }
            #expect(throws: Scenario.ParseError.self) {
                try parse(#"{"name": "x", "steps": [{"step": "window", "width": true, "height": 2}]}"#)
            }
            #expect(throws: Scenario.ParseError.self) { try parse(#"{"steps": []}"#) }
            #expect(throws: Scenario.ParseError.self) { try parse("not json") }
        }

        @Test func resolvesPathsAgainstTheFixtures() throws {
            let scenario = try parse(#"{"name": "x", "root": "lighthouse/Lighthouse", "steps": []}"#)
            let environment = ["FILETRAIL_FIXTURES": "/fixtures"]
            #expect(
                scenario.resolve("app/src", environment: environment).path == "/fixtures/lighthouse/Lighthouse/app/src")
            #expect(scenario.resolve(".", environment: environment).path == "/fixtures/lighthouse/Lighthouse")
            #expect(scenario.resolve("/tmp/x", environment: environment).path == "/tmp/x")
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            #expect(scenario.resolve("~/Empty", environment: environment).path == home + "/Empty")
        }

        @Test func readsTheCommandLine() {
            let options = AutomationRunner.options(from: ["--automation", "/s/a.json", "--out", "/o"])
            #expect(options == .init(scenario: URL(fileURLWithPath: "/s/a.json"), out: URL(fileURLWithPath: "/o")))
            #expect(AutomationRunner.options(from: ["--snapshot", "/x.png"]) == nil)
            #expect(AutomationRunner.options(from: ["--automation"]) == nil)
        }

        @Test func mapsKeysAndModifiers() {
            #expect(KeyEvents.key(named: "Enter")?.keyCode == 36)
            #expect(KeyEvents.key(named: "ArrowDown")?.isFunctionKey == true)
            #expect(KeyEvents.key(named: "a")?.keyCode == 0)
            #expect(KeyEvents.key(named: "[")?.keyCode == 33)
            #expect(KeyEvents.key(named: "NoSuchKey") == nil)
            #expect(KeyEvents.modifiers(["cmd", "shift"]) == [.command, .shift])
            #expect(KeyEvents.modifiers(["hyper"]) == nil)
        }

        @Test func saysOnlyOfASnapshotTakenUnfocused() throws {
            var report = AutomationReport(scenario: "x")
            report.steps.append(.init(index: 1, step: "snapshot", status: .ok, message: nil, milliseconds: 1))
            #expect(try !String(decoding: report.encoded(), as: UTF8.self).contains("unfocused"))
            report.steps.append(
                .init(index: 2, step: "snapshot", status: .ok, message: nil, milliseconds: 1, unfocused: true))
            let decoded = try JSONDecoder().decode(AutomationReport.self, from: report.encoded())
            #expect(decoded.steps.map(\.unfocused) == [nil, true])
            // Unfocused is a remark on a step that was done.
            #expect(decoded.failedCount == 0 && decoded.unsupportedCount == 0)
        }

        @Test func countsUnsupportedAndFailedSteps() throws {
            var report = AutomationReport(scenario: "x")
            for (index, status) in [AutomationReport.Status.ok, .partial, .unsupported, .failed, .timeout].enumerated()
            {
                report.steps.append(.init(index: index + 1, step: "s", status: status, message: nil, milliseconds: 1))
            }
            #expect(report.unsupportedCount == 2)
            #expect(report.failedCount == 2)
            let decoded = try JSONDecoder().decode(AutomationReport.self, from: report.encoded())
            #expect(decoded == report)
        }

        @Test @MainActor func knowsTheOriginalsCommands() {
            #expect(AutomationCommands.all.count == 74)
            #expect(AutomationCommands.supported.isSubset(of: AutomationCommands.all))
            // Every command goes to the window but the zoom ones (DEVIATIONS D-005).
            #expect(
                AutomationCommands.all.subtracting(AutomationCommands.supported) == ["zoomIn", "zoomOut", "resetZoom"])
            #expect(AutomationCommands.supported.allSatisfy { RendererCommand(rawValue: $0) != nil })
        }
    }
#endif
