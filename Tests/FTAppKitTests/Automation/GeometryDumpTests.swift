#if DEBUG
    import AppKit
    import FTFoundation
    import Testing

    @testable import FTAppKit

    @MainActor
    @Suite struct GeometryDumpTests {
        private func window() -> (NSWindow, NSView) {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                backing: .buffered, defer: true)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = content
            window.appearance = NSAppearance(named: .aqua)
            return (window, content)
        }

        @Test func listsNamedViewsWithTopLeftFrames() {
            let (window, content) = window()
            let box = NSView(frame: NSRect(x: 10, y: 250, width: 100, height: 40))
            box.setAccessibilityIdentifier("toolbar")
            content.addSubview(box)
            let unnamed = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            content.addSubview(unnamed)
            let hidden = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            hidden.setAccessibilityIdentifier("hidden")
            hidden.isHidden = true
            content.addSubview(hidden)
            let offscreen = NSView(frame: NSRect(x: 0, y: -500, width: 50, height: 50))
            offscreen.setAccessibilityIdentifier("offscreen")
            content.addSubview(offscreen)

            let dump = GeometryDump(window: window, name: "main")
            #expect(dump.side == "swift")
            #expect(dump.window == .init(width: 400, height: 300))
            #expect(dump.elements.map(\.id) == ["toolbar"])
            #expect(dump.elements.first?.frame == .init(x: 10, y: 10, width: 100, height: 40))
            #expect(dump.elements.first?.text == nil)
            #expect(GeometryDump(window: window, name: "all", allViews: true).elements.count > 2)
        }

        @Test func describesText() throws {
            let (window, content) = window()
            let label = NSTextField(labelWithString: "Favorites")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
            label.frame = NSRect(x: 0, y: 0, width: 80, height: 14)
            label.setAccessibilityIdentifier("sidebar.sectionHeader")
            content.addSubview(label)

            let element = try #require(GeometryDump(window: window, name: "main").elements.first)
            #expect(element.text == .init(string: "Favorites", fontSize: 11, fontWeight: 600, color: "#00000080"))
            #expect(element.frame == .init(x: 0, y: 286, width: 80, height: 14))
        }

        @Test func encodesTheSharedFormat() throws {
            let dump = GeometryDump(
                side: "swift", name: "main", window: .init(width: 1200, height: 760),
                elements: [
                    .init(
                        id: "title", frame: .init(x: 1, y: 2, width: 3, height: 4),
                        text: .init(string: "components", fontSize: 15, fontWeight: 700, color: "#1d1d1f"))
                ])
            let json = try #require(JSONSerialization.jsonObject(with: dump.encoded()) as? [String: Any])
            #expect(json["format"] as? String == "filetrail-geometry/1")
            #expect(json["name"] as? String == "main")
            let element = try #require((json["elements"] as? [[String: Any]])?.first)
            #expect(Set(element.keys) == ["id", "frame", "text"])
            #expect(Set((element["frame"] as? [String: Any])?.keys ?? [:].keys) == ["x", "y", "width", "height"])
            #expect(
                Set((element["text"] as? [String: Any])?.keys ?? [:].keys) == [
                    "string", "fontSize", "fontWeight", "color",
                ])
        }

        @Test func convertsWeightsAndColors() {
            #expect(GeometryDump.cssWeight(NSFont.Weight.regular.rawValue) == 400)
            #expect(GeometryDump.cssWeight(NSFont.Weight.semibold.rawValue) == 600)
            #expect(GeometryDump.cssWeight(NSFont.Weight.bold.rawValue) == 700)
            #expect(GeometryDump.hex(red: 1, green: 0.5, blue: 0, alpha: 1) == "#ff8000")
            #expect(GeometryDump.hex(red: 0, green: 0, blue: 0, alpha: 0.5) == "#00000080")
        }

        @Test func namesAppKitsToolbarViews() {
            let button = NSButton(image: NSImage(size: .zero), target: nil, action: nil)
            #expect(AutomationTags.systemName(of: button) == nil)
            #expect(AutomationTags.systemName(of: NSView()) == nil)
        }

        @Test func readsTheFrozenClock() throws {
            let utc = try #require(TimeZone(identifier: "UTC"))
            let date = try #require(AppClock.parse("2026-10-13T14:38:00", timeZone: utc))
            #expect(date.timeIntervalSince1970 == 1_791_902_280)
            #expect(AppClock.parse("2026-10-13T14:38:00Z") == date)
            #expect(AppClock.parse("2026-10-13T16:38:00+02:00") == date)
            #expect(AppClock.parse("2026-10-13T14:38", timeZone: utc) == date)
            #expect(AppClock.parse("yesterday") == nil)
            #expect(AppClock.parse("") == nil)
            if !AppClock.isFrozen { #expect(abs(AppClock.now.timeIntervalSinceNow) < 5) }
        }
    }
#endif
