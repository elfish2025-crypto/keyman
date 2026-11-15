import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

@Test(arguments: [
    ["key", "set", "account", "--key", "secret-must-not-echo"],
    ["profile", "add", "--file", "profile.json", "--key-stdin", "--key-file", "secret.txt"],
    ["profile", "update", "account", "--file", "patch.json", "--key-stdin"],
    ["key", "clear", "account", "--file", "wrong.json"],
    ["model", "delete", "account"],
    ["endpoint", "enable", "account", "default"],
    ["profile", "get", "account", "--dry-run"]
])
func invalidManagementArgumentsFailWithoutEchoingPotentialSecrets(arguments: [String]) {
    do { _ = try CLIParser.parse(arguments); Issue.record("Expected invalid arguments") }
    catch { #expect(!error.localizedDescription.contains("secret-must-not-echo")) }
}

@Test
func agentCanManageAccountEndpointModelAndCredentialWithoutAProviderCall() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = InMemoryConfigurationStore()
    let keys = InMemoryCredentialStore()
    let app = CLIApplication(configurationStore: config, credentialStore: keys, modelCaller: StubModelCaller(), commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    func document(_ body: String) throws -> String {
        let path = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(body.utf8).write(to: path)
        return path.path
    }
    func run(_ args: [String], secret: String = "") async throws -> CLIResult {
        let result = await app.execute(arguments: args, stdin: { Data(secret.utf8) })
        #expect(result.exitCode == 0, "\(args.prefix(3)): \(String(decoding: result.stdout, as: UTF8.self))")
        #expect(!String(decoding: result.stdout + result.stderr, as: UTF8.self).contains("synthetic-secret"))
        return result
    }
    let profileFile = try document(#"{"alias":"agent-account","name":"Agent Test","provider":"custom-rest","authentication":{"headerName":"Authorization","prefix":"Bearer","environmentVariable":"TEST_API_KEY"}}"#)
    let dry = try await run(["profile", "add", "--file", profileFile, "--key-stdin", "--dry-run"], secret: "synthetic-secret-original")
    #expect((try JSONSerialization.jsonObject(with: dry.stdout) as? [String: Any])?["dryRun"] as? Bool == true)
    #expect(try await config.load().profiles.isEmpty)
    _ = try await run(["profile", "add", "--file", profileFile, "--key-stdin"], secret: "synthetic-secret-original")
    let id = try #require(try await config.load().profiles.first?.id)
    #expect(try await keys.load(for: id) == "synthetic-secret-original")
    _ = try await run(["endpoint", "add", "agent-account", "--file", try document(#"{"alias":"default","name":"Test Interface","baseURL":"http://127.0.0.1:9999/v1"}"#)])
    _ = try await run(["model", "add", "agent-account", "--file", try document(#"{"alias":"text","name":"Text","modelID":"fixture-v1","modality":"text","status":"declared","callTemplate":{"endpointAlias":"default","path":"/chat/completions","modelIDBodyField":"model"}}"#)])
    _ = try await run(["endpoint", "update", "agent-account", "default", "--file", try document(#"{"alias":"primary"}"#)])
    #expect(try await config.load().profiles[0].models[0].callTemplate?.endpointAlias == "primary")
    _ = try await run(["profile", "update", "agent-account", "--file", try document(#"{"alias":"renamed-account","notes":"Retain models"}"#)])
    #expect(try await config.load().profiles[0].models.count == 1)
    _ = try await run(["profile", "disable", "renamed-account"])
    let blocked = await app.execute(arguments: ["preflight", "renamed-account", "text", "--body-stdin"], stdin: { Data("{}".utf8) })
    #expect(blocked.exitCode == 1)
    #expect(String(decoding: blocked.stdout, as: UTF8.self).contains("profile_disabled"))
    _ = try await run(["profile", "enable", "renamed-account"])
    _ = try await run(["model", "disable", "renamed-account", "text"])
    #expect(try await config.load().profiles[0].models[0].status == .declared)
    _ = try await run(["model", "enable", "renamed-account", "text"])
    _ = try await run(["model", "update", "renamed-account", "text", "--file", try document(#"{"name":"Edited Model"}"#)])
    _ = try await run(["key", "set", "renamed-account", "--key-stdin"], secret: "synthetic-secret-replacement")
    #expect(try await keys.load(for: id) == "synthetic-secret-replacement")
    _ = try await run(["key", "status", "renamed-account"])
    _ = try await run(["key", "clear", "renamed-account"])
    #expect(try await config.load().profiles.count == 1)
    _ = try await run(["model", "delete", "renamed-account", "text"])
    _ = try await run(["endpoint", "delete", "renamed-account", "primary"])
    _ = try await run(["profile", "delete", "renamed-account"])
    #expect(try await config.load().profiles.isEmpty)
    #expect(try await config.load().outputPolicy == .noVisibleWatermark)
}

@Test
func metadataCommandsAndDisabledRunWorkWithoutKeychainAuthorization() async throws {
    let profile = try ManagementDocuments.profile(Data(#"{"alias":"account","name":"Account","isEnabled":false}"#.utf8))
    let config = InMemoryConfigurationStore(.init(profiles: [profile], outputPolicy: .providerDefault))
    let app = CLIApplication(configurationStore: config, credentialStore: FailingCredentialStore(), modelCaller: StubModelCaller(), commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    for args in [["profile", "list"], ["profile", "get", "account"], ["endpoint", "list", "account"], ["model", "list", "account"]] {
        #expect(await app.execute(arguments: args, stdin: { Data() }).exitCode == 0)
    }
    let result = await app.execute(arguments: ["run", "account", "--", "test-command"], stdin: { Data() })
    #expect(String(decoding: result.stdout, as: UTF8.self).contains("profile_disabled"))
    #expect(!String(decoding: result.stdout, as: UTF8.self).contains("keychain_denied"))
}
