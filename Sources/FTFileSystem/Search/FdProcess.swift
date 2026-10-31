// Port of the child_process.spawn call in packages/core/src/search/fdSearch.ts (stdin ignored, stdout and stderr piped)
import Darwin
import Foundation

/// A real `fd` process, started with `posix_spawn` so the arguments reach it byte for byte, as Node passes them
/// (Foundation's `Process` would write "é" decomposed, and a query typed as "é" would no longer find a file named so).
/// Output is read on one thread per pipe; `onClose` comes after the process has ended and both pipes have been read to
/// the end, as Node's `close` event does.
public final class FdProcess: SearchProcess, @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var reaped = false

    private init(pid: pid_t) {
        self.pid = pid
    }

    /// One start at a time, so no other child can inherit a pipe's write end while it is being set up.
    private static let spawnLock = NSLock()

    public static let spawn: SearchSpawn = { file, args, cwd, events in
        let result = spawnLock.withLock { start(file: file, args: args, cwd: cwd) }
        switch result {
        case .failure(let failure):
            // Reported afterwards, as an event, like Node's `error`.
            DispatchQueue.global().async { events.onError(failure.message) }
            return FdProcess(pid: 0)
        case .success(let started):
            let process = FdProcess(pid: started.pid)
            let finished = DispatchGroup()
            for (descriptor, deliver) in [(started.stdout, events.onStdout), (started.stderr, events.onStderr)] {
                finished.enter()
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let count = read(descriptor, &buffer, buffer.count)
                        if count > 0 {
                            deliver(Data(buffer[0..<count]))
                        } else if count < 0 && errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    close(descriptor)
                    finished.leave()
                }
            }
            finished.enter()
            Thread.detachNewThread {
                var status: Int32 = 0
                while waitpid(started.pid, &status, 0) < 0 && errno == EINTR {}
                process.lock.withLock { process.reaped = true }
                finished.leave()
                // The exit status as Node reports it: the code, or the signal that ended the process.
                let signaled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
                finished.notify(queue: .global()) {
                    events.onClose(signaled ? nil : (status >> 8) & 0xff, signaled ? status & 0x7f : nil)
                }
            }
            return process
        }
    }

    private struct SpawnFailure: Error {
        var message: String
    }

    private struct Started {
        var pid: pid_t
        var stdout: Int32
        var stderr: Int32
    }

    private static func start(file: String, args: [String], cwd: String) -> Result<Started, SpawnFailure> {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { return .failure(SpawnFailure(message: "spawn \(file) failed: pipe")) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            return .failure(SpawnFailure(message: "spawn \(file) failed: pipe"))
        }
        defer {
            // The parent keeps the read ends only.
            close(outPipe[1])
            close(errPipe[1])
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors set up above reach the child, and it starts with every signal at its default and none
        // blocked (as Node starts children), whatever this process has ignored or blocked: it must die on SIGTERM.
        var defaults = sigset_t()
        sigfillset(&defaults)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var argv: [UnsafeMutablePointer<CChar>?] = ([file] + args).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, file, &actions, &attributes, argv, environ)
        guard code == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            return .failure(SpawnFailure(message: "spawn \(file) \(errnoName(code))"))
        }
        return .success(Started(pid: pid, stdout: outPipe[0], stderr: errPipe[0]))
    }

    private static func errnoName(_ code: Int32) -> String {
        switch code {
        case ENOENT: "ENOENT"
        case EACCES: "EACCES"
        case ENOTDIR: "ENOTDIR"
        case ENOEXEC: "ENOEXEC"
        case EAGAIN: "EAGAIN"
        case ENOMEM: "ENOMEM"
        default: "errno \(code)"
        }
    }

    /// The process id, for checking that it is gone.
    public var processIdentifier: Int32 { pid }

    public func terminate() {
        lock.withLock {
            // SIGTERM, only until the process has been reaped: after that its id may belong to another process.
            if pid > 0 && !reaped {
                kill(pid, SIGTERM)
            }
        }
    }
}
