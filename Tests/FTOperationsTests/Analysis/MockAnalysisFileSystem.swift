// Port of what the review's tests use of MockWriteServiceFileSystem (packages/core/src/fs/testUtils.ts): the items in
// memory (MockIdentityFileSystem), with the hooks the tests replace calls with, and the volume's case answer.
import FTFoundation
import Foundation
import os

@testable import FTOperations

final class MockAnalysisFileSystem: AnalysisFileSystem, @unchecked Sendable {
    typealias Seed = MockIdentityFileSystem.Seed

    let base: MockIdentityFileSystem
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var realpathOverrides: [String: String] = [:]
    var lstatImpl: ((String) throws -> WriteServiceStats)?
    var readdirImpl: ((String) throws -> [String])?
    var realpathImpl: ((String) throws -> String)?
    /// Replaces the volume's case answer.
    var isCaseSensitiveImpl: ((String) throws -> Bool?)?
    /// false: the file system has no case answer at all, so the review looks for itself.
    var answersCase = true

    /// The macOS default; tests of case-sensitive volumes set this to true.
    var caseSensitive: Bool {
        get { base.caseSensitive }
        set { base.caseSensitive = newValue }
    }

    /// How many times `lstat` was called.
    var lstatCount: Int { calls.withLock { $0 } }

    /// Items made in order; a path given twice keeps its first place and its last seed, as a JavaScript object
    /// spread does.
    init(_ seed: [(String, Seed)] = []) {
        var merged: [(String, Seed)] = []
        for (path, node) in seed {
            if let index = merged.firstIndex(where: { $0.0 == path }) {
                merged[index].1 = node
            } else {
                merged.append((path, node))
            }
        }
        base = MockIdentityFileSystem(merged)
    }

    func addFile(_ path: String, size: Int64) {
        base.add(path, .file(size: size))
    }

    func setRealpath(_ path: String, _ realPath: String) {
        realpathOverrides[path] = realPath
    }

    func lstat(_ path: String) throws -> WriteServiceStats {
        calls.withLock { $0 += 1 }
        if let lstatImpl {
            return try lstatImpl(path)
        }
        return try base.lstat(path)
    }

    func stat(_ path: String) throws -> WriteServiceStats {
        try base.stat(path)
    }

    func realpath(_ path: String) throws -> String {
        if let realpathImpl {
            return try realpathImpl(path)
        }
        if let override = realpathOverrides[path] {
            return override
        }
        return try base.realpath(path)
    }

    func readdir(_ path: String) throws -> [String] {
        if let readdirImpl {
            return try readdirImpl(path)
        }
        return try base.readdir(path)
    }

    func readlink(_ path: String) throws -> String {
        try base.readlink(path)
    }

    func isCaseSensitive(_ path: String) throws -> Bool? {
        if let isCaseSensitiveImpl {
            return try isCaseSensitiveImpl(path)
        }
        return answersCase ? caseSensitive : nil
    }
}

/// An error with a code, as Node's fs throws them.
func codedError(_ code: String, _ message: String? = nil) -> NativeError {
    NativeError(message: message ?? code, code: code)
}

/// Polls `condition` until it holds or `timeout` passes, as `vi.waitFor` does.
func waitFor(timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if (try? condition()) == true {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return (try? condition()) == true
}
