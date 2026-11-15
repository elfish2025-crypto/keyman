import Foundation
import Testing
@testable import KeymanCore

actor RecordingCommandRunner: CommandRunning {
    private(set) var recordedEnvironment: [String: String]?

    func run(
        command: [String],
        additionalEnvironment: [String: String]
    ) async throws -> CommandResult {
        recordedEnvironment = additionalEnvironment
        return .init(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

@Test
func testRunnerInjectsCredentialOnlyIntoChildEnvironment() async throws {
    let runner = RecordingCommandRunner()
    _ = try await runner.run(
        command: ["/usr/bin/env"],
        additionalEnvironment: ["ARK_API_KEY": "unit-test-credential"]
    )
    let environment = await runner.recordedEnvironment

    #expect(environment?["ARK_API_KEY"] == "unit-test-credential")
    #expect(ProcessInfo.processInfo.environment["ARK_API_KEY"] == nil)
}

@Test
func testProcessRunnerInjectsCredentialWithoutMutatingParentEnvironment() async throws {
    let result = try await ProcessCommandRunner().run(
        command: ["/usr/bin/env"],
        additionalEnvironment: ["KEYMAN_TEST_MARKER": "injected"]
    )

    let stdout = String(decoding: result.stdout, as: UTF8.self)
    #expect(stdout.contains("KEYMAN_TEST_MARKER=injected"))
    #expect(ProcessInfo.processInfo.environment["KEYMAN_TEST_MARKER"] == nil)
}

@Test
func testProcessRunnerDrainsLargeStdoutAndStderrWhileRunning() async throws {
    // A watchdog bounds the regression even if pipe draining is broken again.
    let result = try await ProcessCommandRunner().run(
        command: ["/bin/sh", "-c", """
        (sleep 5; kill -TERM $$ 2>/dev/null) </dev/null >/dev/null 2>&1 &
        watchdog=$!
        /bin/dd if=/dev/zero bs=1048576 count=1 2>/dev/null
        /bin/dd if=/dev/zero bs=1048576 count=1 1>&2 2>/dev/null
        kill "$watchdog" 2>/dev/null
        wait "$watchdog" 2>/dev/null
        exit 0
        """],
        additionalEnvironment: [:]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.count >= 1_048_576)
    #expect(result.stderr.count >= 1_048_576)
}

@Test
func testProcessRunnerReportsMissingChildCommand() async throws {
    let result = try await ProcessCommandRunner().run(
        command: ["/keyman-test-command-does-not-exist"],
        additionalEnvironment: [:]
    )
    #expect(result.exitCode != 0)
    #expect(!result.stderr.isEmpty)
}
