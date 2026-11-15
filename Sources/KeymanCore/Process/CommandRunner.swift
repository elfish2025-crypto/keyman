import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(
        command: [String],
        additionalEnvironment: [String: String]
    ) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        command: [String],
        additionalEnvironment: [String: String]
    ) async throws -> CommandResult {
        guard !command.isEmpty else {
            throw KeymanError.invalidRequest("子进程命令不能为空")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            process.environment = ProcessInfo.processInfo.environment
                .merging(additionalEnvironment) { _, new in new }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let readers = DispatchGroup()
            let output = CollectedOutput()
            // Drain both pipes while the child runs. Waiting for termination
            // before reading lets a full pipe block the child indefinitely.
            readers.enter()
            readers.enter()
            process.terminationHandler = { process in
                readers.notify(queue: .global()) {
                    continuation.resume(returning: output.result(exitCode: process.terminationStatus))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().async {
                    output.setStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }
                DispatchQueue.global().async {
                    output.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }
            } catch {
                process.terminationHandler = nil
                readers.leave()
                readers.leave()
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) { lock.withLock { stdout = data } }
    func setStderr(_ data: Data) { lock.withLock { stderr = data } }
    func result(exitCode: Int32) -> CommandResult {
        lock.withLock { CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr) }
    }
}
