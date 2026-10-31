// The capture automation's steps on an explorer window that is never shown: commands go to the window's own handler,
// and a shared preference with no handler of its own goes out as Settings sends it
#if DEBUG
    import AppKit
    import FTFoundation
    import Testing

    @testable import FTAppKit

    extension ExplorerWindowlessTests {
        @MainActor
        @Suite struct AutomationWindowTests {
            @Test func commandsGoToTheWindowsOwnHandler() async throws {
                let harness = try ExplorerHarness.windowless()
                let tab = try await harness.open()
                let window = try #require(tab.window)
                #expect(AutomationCommands.run("viewAsIcons", controller: tab, window: window).status == .ok)
                #expect(tab.viewMode == .icons)
                #expect(AutomationCommands.run("viewAsDetails", controller: tab, window: window).status == .ok)
                #expect(tab.viewMode == .details)
                let open = tab.panels.propertiesOpen
                #expect(AutomationCommands.run("toggleInfoPanel", controller: tab, window: window).status == .ok)
                #expect(tab.panels.propertiesOpen == !open)
                // The zoom commands are the system's here (D-005); an id the original doesn't have is an error.
                #expect(AutomationCommands.run("zoomIn", controller: tab, window: window).status == .unsupported)
                #expect(AutomationCommands.run("explode", controller: tab, window: window).status == .failed)
                await harness.close()
            }

            @Test func sharedPreferencesWithoutAHandlerGoOutAsSettingsSendsThem() async throws {
                let harness = try ExplorerHarness.windowless()
                let tab = try await harness.open()
                let window = try #require(tab.window)
                #expect(tab.preferences.returnKeyAction == .rename)
                func apply(_ prefs: [String: Scenario.PrefValue]) -> AutomationRunner.Outcome {
                    AutomationPrefs.apply(prefs, context: .init(controller: tab, window: window, prefs: prefs))
                }
                #expect(!AutomationPrefs.hasHandler("returnKeyAction"))
                #expect(apply(["returnKeyAction": .string("open")]).status == .ok)
                #expect(tab.preferences.returnKeyAction == .open)
                // A window session key is only seeded before launch in the original's driver.
                #expect(!AutomationPrefs.hasHandler("lastVisitedPath"))
                let session = apply(["lastVisitedPath": .string("/")])
                #expect(session.status == .partial)
                #expect(session.message == "unsupported: lastVisitedPath")
                await harness.close()
            }
        }
    }
#endif
