import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

@Test func taskCommandNeverCreatesGenerationAndPendingIsDistinctFromFailure() async throws {
    for state in ["running", "failed", "succeeded"] {
        let caller = QueryOnlyCaller(status: state)
        let app = CLIApplication(configurationStore: InMemoryConfigurationStore(), credentialStore: FailingCredentialStore(),
            modelCaller: caller, commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
        let result = await app.execute(arguments: ["task", "profile", "video", "task-1"], stdin: { Data() })
        #expect(result.exitCode == (state == "running" ? 3 : state == "failed" ? 1 : 0))
        let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        #expect(object?["generationRequestSent"] as? Bool == false)
        #expect(object?["automaticRetryAllowed"] as? Bool == false)
        #expect(await caller.calls == 0)
        #expect(await caller.queries == 1)
    }
}

@Test func taskAndMoveCLIRejectAmbiguousArguments() throws {
    #expect(try CLIParser.parse(["task", "p", "m", "id", "--wait-seconds", "20"]) == .task(profile: "p", model: "m", id: "id", waitSeconds: 20))
    for args in [["task", "p", "m"], ["task", "p", "m", "id", "--wait-seconds", "-1"], ["task", "p", "m", "id", "--wait-seconds", "601"], ["model", "move", "p", "m", "p2"]] {
        #expect(throws: KeymanError.self) { try CLIParser.parse(args) }
    }
    guard case .management(let command) = try CLIParser.parse(["model", "move", "p", "m", "p2", "--file", "patch.json", "--dry-run"]) else { Issue.record("Expected move command"); return }
    #expect(command.destinationAlias == "p2" && command.dryRun)
}

private actor QueryOnlyCaller: ModelCalling {
    let status: String
    private(set) var calls = 0, queries = 0
    init(status: String) { self.status = status }
    func call(profileAlias: String, modelAlias: String, body: Data, policyOverride: OutputPolicy?) async throws -> CallResponse {
        calls += 1; throw KeymanError.invalidRequest("must never create")
    }
    func query(profileAlias: String, modelAlias: String, taskID: String) async throws -> CallResponse {
        queries += 1
        let progress = try JSONDecoder().decode(TaskProgress.self, from: JSONSerialization.data(withJSONObject: [
            "id": taskID, "status": status, "terminal": status != "running", "succeeded": status == "succeeded", "queryCommand": ["keyman", "task", profileAlias, modelAlias, taskID]
        ]))
        return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), isAsync: status == "running", task: progress, generationRequestSent: false)
    }
}
