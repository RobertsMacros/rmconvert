import Foundation
import Darwin

struct ProcessResult { var status: Int32; var output: String; var error: String }

enum ProcessRunner {
    static var helper: URL {
        if let override = ProcessInfo.processInfo.environment["RMCONVERT_EXEC_HELPER"] { return URL(fileURLWithPath: override) }
        return RMPaths.resourceDirectory.deletingLastPathComponent().appendingPathComponent("MacOS/rmconvert-exec")
    }
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], in directory: URL, timeout: Double = 120, accepted: Set<Int32> = [0]) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw RMError("The converter is missing: \(executable). Open rmconvert and check converters.") }
        let stdout = directory.appendingPathComponent("stdout-\(UUID().uuidString)"), stderr = directory.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdout.path, contents: nil); FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close(); try? FileManager.default.removeItem(at: stdout); try? FileManager.default.removeItem(at: stderr) }
        let process = Process(); process.executableURL = helper
        process.arguments = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)(allow network* (local unix-socket) (remote unix-socket))", executable] + arguments
        process.currentDirectoryURL = directory; process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "en_US.UTF-8"; process.environment = environment
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            kill(-process.processIdentifier, SIGTERM)
            let parentFinished = finished.wait(timeout: .now() + 2) != .timedOut
            // A terminated parent can leave children which ignore SIGTERM.
            kill(-process.processIdentifier, SIGKILL)
            if !parentFinished { _ = finished.wait(timeout: .now() + 2) }
            throw RMError("\(URL(fileURLWithPath: executable).lastPathComponent) exceeded its \(Int(timeout))-second time limit. The original is unchanged.")
        }
        func read(_ url: URL) -> String {
            guard let file = try? FileHandle(forReadingFrom: url) else { return "" }; defer { try? file.close() }
            return String(decoding: (try? file.read(upToCount: 1_000_000)) ?? Data(), as: UTF8.self)
        }
        let result = ProcessResult(status: process.terminationStatus, output: read(stdout), error: read(stderr))
        guard accepted.contains(result.status) else { throw RMError("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(result.status)): \((result.error.isEmpty ? result.output : result.error).prefix(1600))") }
        return result
    }
}

final class ProcessLock {
    private var file: Int32 = -1
    init(name: String, slots: Int = 1, timeout: Double = 120) throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/rmconvert")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let end = Date().addingTimeInterval(timeout)
        while true {
            for slot in 0..<slots {
                let candidate = open(folder.appendingPathComponent("\(name)-\(slot).lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
                guard candidate >= 0 else { throw RMError("Could not open the converter queue.") }
                if flock(candidate, LOCK_EX | LOCK_NB) == 0 { file = candidate; return }
                close(candidate)
            }
            if Date() > end { throw RMError("The converter is busy. Try again when the current job finishes.") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    deinit { if file >= 0 { flock(file, LOCK_UN); close(file) } }
}
