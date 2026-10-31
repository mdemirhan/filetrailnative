#if DEBUG
    import AppKit
    import FTFoundation
    import Testing
    @testable import FTAppKit

    extension ExplorerWindowlessTests {
        @MainActor
        @Suite struct P023ParityProbeTests {
            /// The driver sends Select All to the scenario's window, which need not be key: the list it focuses selects
            /// every entry (`runGenericEditCommand`, `selectAllContentEntries`).
            @Test func selectAllCommandSelectsTheList() async throws {
                let harness = try ExplorerHarness.windowless()
                let tab = try await harness.open()
                let window = try #require(tab.window)
                tab.perform(.viewAsDetails)
                #expect(await waitUntil { tab.content.entries.count == 4 })
                #expect(AutomationCommands.run("focusContentPane", controller: tab, window: window).status == .ok)
                #expect(tab.focusedPane == .content)
                #expect(AutomationCommands.run("editSelectAll", controller: tab, window: window).status == .ok)
                #expect(await waitUntil { tab.selectedPaths.count == 4 })
                await harness.close()
            }
        }
    }
#endif
