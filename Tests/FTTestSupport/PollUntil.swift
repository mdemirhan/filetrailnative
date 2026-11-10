import Testing

/// Waits until `condition` holds, looking every 10 ms. The work waited for runs as tasks whose speed depends on the
/// machine's load, so the limit only matters to a test that is failing: that one records where it gave up.
@MainActor
public func pollUntil(
    timeout: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record(Comment(rawValue: "gave up waiting after \(timeout)"), sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
