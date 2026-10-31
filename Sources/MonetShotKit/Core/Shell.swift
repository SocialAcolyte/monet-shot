import Foundation
import Synchronization

/// Runs an external tool and captures its output. Rules carried over from
/// Insomnia: tools are called by absolute path (never via PATH), every call
/// has a time limit, and nothing goes through a shell string, so arguments
/// can never be reinterpreted.
public protocol ShellRunning: Sendable {
    func run(_ tool: String, _ args: [String], input: Data?, timeout: Duration) async -> ShellResult
}

extension ShellRunning {
    public func run(_ tool: String, _ args: [String], timeout: Duration) async -> ShellResult {
        await run(tool, args, input: nil, timeout: timeout)
    }
}

public struct ShellResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut = false
    public var ok: Bool { status == 0 && !timedOut }

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
}

public struct Shell: ShellRunning {
    public init() {}

    /// Foundation's Process throws an uncatchable exception above this many arguments.
    public static let maxArguments = 4000

    public func run(_ tool: String, _ args: [String], input: Data? = nil, timeout: Duration = .seconds(10)) async -> ShellResult {
        guard args.count <= Self.maxArguments else {
            return ShellResult(status: -1, stdout: "", stderr: "too many arguments (\(args.count)); pass them as input")
        }
        // Blocking pipe reads run off the cooperative pool.
        return await Task.detached { Self.runBlocking(tool, args, input: input, timeout: timeout) }.value
    }

    private static func runBlocking(_ tool: String, _ args: [String], input: Data?, timeout: Duration) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
        do { try process.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: "\(error)")
        }
        if let stdin, let input {
            // Write on another thread so a full stdout pipe can't deadlock us.
            let writer = stdin.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        let killed = Atomic<Bool>(false)
        let deadline = DispatchWorkItem {
            if process.isRunning {
                killed.store(true, ordering: .relaxed)
                process.terminate()
            }
        }
        let c = timeout.components
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)), execute: deadline)
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        deadline.cancel()
        let timedOut = killed.load(ordering: .relaxed)
        if timedOut { Log.error("\(tool) timed out after \(timeout)") }
        return ShellResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }
}
