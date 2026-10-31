// A window's occlusion changing tells the clock only when whether any can be seen changed
import AppKit
import Testing

@testable import FTAppKit

@MainActor
@Suite struct WindowVisibilityMonitorTests {
    // B-INFO-083 B-INFO-197
    @Test func saysOnlyWhenTheAnswerChanges() {
        let center = NotificationCenter()
        var visible = true
        var told = 0
        let monitor = WindowVisibilityMonitor(center: center, isVisible: { visible }, changed: { told += 1 })
        func post() { center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil) }
        withExtendedLifetime(monitor) {
            post()
            #expect(told == 0)
            visible = false
            post()
            post()
            #expect(told == 1)
            visible = true
            post()
            #expect(told == 2)
        }
    }
}
