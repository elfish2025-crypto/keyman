import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

private final class MCPMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ data: Data) { lock.withLock { values.append(data) } }
    var messages: [JSONValue] { lock.withLock { values.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } } }
    var raw: [Data] { lock.withLock { values } }
    func wait(count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while messages.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(messages.count >= count)
    }
}

private func mcpApp(config: InMemoryConfigurationStore = .init(), keys: any CredentialStoring = FailingCredentialStore(),
                    caller: any ModelCalling = StubModelCaller()) -> CLIApplication {
    .init(configurationStore: config, credentialStore: keys, modelCaller: caller,
          commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
}

private func mcpProfile() throws -> ProviderProfile {
    var profile = try ManagementDocuments.profile(Data(#"{"alias":"account","name":"MCP fixture","provider":"custom-rest","authentication":{"headerName":"Authorization","prefix":"Bearer","environmentVariable":"TEST_API_KEY"},"endpoints":[{"alias":"main","name":"Fixture","baseURL":"http://127.0.0.1:9999/v1"}]}"#.utf8))
    profile.models = [try ManagementDocuments.model(Data(#"{"alias":"text","name":"Text","modelID":"fixture-v1","modality":"text","status":"declared","callTemplate":{"endpointAlias":"main","path":"/chat/completions","modelIDBodyField":"model","requiredBodyFields":["prompt"]},"usageGuide":{"summary":"测试文字模型","inputs":"prompt","outputs":"text","requestExample":{"prompt":"hello"}}}"#.utf8))]
    return profile
}

private func mcpSend(_ server: MCPServer, _ json: String) async { await server.receive(Data(json.utf8)) }
private func mcpReady(_ server: MCPServer) async {
    await mcpSend(server, #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
    await mcpSend(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
}

@Test func mcpLifecycleNegotiatesAndEnforcesInitializationWithoutReadingKeys() async throws {
    let messages = MCPMessages()
    let server = MCPServer(application: mcpApp()) { messages.append($0) }
    await mcpSend(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    #expect(messages.messages.last?["error"]?["code"] == .integer(-32002))
    await mcpSend(server, #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"future","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
    #expect(messages.messages.last?["result"]?["protocolVersion"] == .string("2025-11-25"))
    #expect(messages.messages.last?["id"] == .string("init"))
    await mcpSend(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    await mcpSend(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let tools = try #require(messages.messages.last?["result"]?["tools"]?.arrayValue)
    #expect(tools.count == MCPToolAdapter.tools.count)
    #expect(Set(tools.compactMap { $0["name"]?.stringValue }).count == tools.count)
    #expect(!tools.contains { $0["name"] == .string("keyman_run") })
    #expect(tools.first { $0["name"] == .string("keyman_call") }?["annotations"]?["readOnlyHint"] == .bool(false))
    await mcpSend(server, #"{"jsonrpc":"2.0","method":"unknown_notification"}"#)
    #expect(messages.messages.count == 3)
    for raw in messages.raw {
        #expect(raw.last == 10)
        #expect(raw.filter { $0 == 10 }.count == 1)
    }
    await server.shutdown()
}

@Test(arguments: [
    ("[1,2]", Int64(-32600)), ("{broken", -32700),
    (#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, -32600),
    (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#, -32602),
    (#"{"jsonrpc":"2.0","id":1,"method":"missing"}"#, -32601)
])
func mcpProtocolErrorsAreStructured(input: String, code: Int64) async throws {
    let messages = MCPMessages(); let server = MCPServer(application: mcpApp()) { messages.append($0) }
    await mcpReady(server); await mcpSend(server, input)
    #expect(messages.messages.last?["error"]?["code"] == .integer(code))
    await server.shutdown()
}

@Test func mcpFramerHandlesChunksCRLFAndOversizeWithoutExecutingPartialMessages() throws {
    var framer = MCPLineFramer()
    #expect(framer.append(Data("{\"a\":".utf8)).isEmpty)
    let completed = framer.append(Data("1}\r\n\n{}\n".utf8))
    #expect(completed.count == 2)
    if case .message(let data) = completed[0] { #expect(try JSONDecoder().decode(JSONValue.self, from: data)["a"] == .integer(1)) }
    else { Issue.record("Expected message") }
    let tooLarge = framer.append(Data(repeating: 120, count: MCPLineFramer.limit + 100))
    #expect(tooLarge.count == 1)
    if case .oversized = tooLarge[0] {} else { Issue.record("Expected oversized event") }
    let recovered = framer.append(Data("ignored\n{}\n".utf8))
    #expect(recovered.count == 1)
    if case .message(let data) = recovered[0] { #expect(data == Data("{}".utf8)) }
}

@Test func mcpInvalidArgumentsNeverDispatchOrEchoCredentialInput() async throws {
    let messages = MCPMessages(); let server = MCPServer(application: mcpApp()) { messages.append($0) }
    await mcpReady(server)
    for (index, arguments) in [
        #"{"name":"keyman_profile","arguments":{"profile":"--key-stdin"}}"#,
        #"{"name":"keyman_credential_set_file","arguments":{"profile":"account","path":"/tmp/key","key":"must-not-echo"}}"#,
        #"{"name":"keyman_manage_profile","arguments":{"action":"delete"}}"#,
        #"{"name":"arbitrary_shell","arguments":{"command":"must-not-echo"}}"#,
        #"{"name":"keyman_task","arguments":{"profile":"account","model":"text","taskId":"id","waitSeconds":61}}"#
    ].enumerated() {
        await mcpSend(server, "{\"jsonrpc\":\"2.0\",\"id\":\(index + 1),\"method\":\"tools/call\",\"params\":\(arguments)}")
    }
    try await messages.wait(count: 6)
    #expect(messages.messages.dropFirst().allSatisfy { $0["error"]?["code"] == .integer(-32602) })
    #expect(!String(decoding: messages.raw.reduce(Data(), +), as: UTF8.self).contains("must-not-echo"))
    await server.shutdown()
}

@Test func mcpManagesProfilesEndpointsModelsAndKeysWithPreviewAndReadback() async throws {
    let config = InMemoryConfigurationStore(); let keys = InMemoryCredentialStore()
    let adapter = MCPToolAdapter(application: mcpApp(config: config, keys: keys))
    func call(_ name: String, _ json: String) async throws -> JSONValue {
        let result = try await adapter.call(name: name, arguments: JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8)))
        #expect(result["isError"] == .bool(false), "\(name): \(result)")
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("synthetic-mcp-secret"))
        return result
    }
    _ = try await call("keyman_manage_profile", #"{"action":"add","document":{"alias":"fixture","name":"MCP fixture"}}"#)
    #expect(try await config.load().profiles.isEmpty)
    _ = try await call("keyman_manage_profile", #"{"action":"add","document":{"alias":"fixture","name":"MCP fixture"},"dryRun":false}"#)
    _ = try await call("keyman_manage_endpoint", #"{"action":"add","profile":"fixture","document":{"alias":"api","name":"Fixture","baseURL":"https://example.com/v1"},"dryRun":false}"#)
    _ = try await call("keyman_manage_model", #"{"action":"add","profile":"fixture","document":{"alias":"model","name":"Fixture model","modality":"text","usageGuide":{"summary":"写作测试","inputs":"prompt","outputs":"text"}},"dryRun":false}"#)
    _ = try await call("keyman_manage_model", #"{"action":"update","profile":"fixture","model":"model","document":{"usageGuide":{"summary":"改写用途"}},"dryRun":false}"#)
    let guide = try await call("keyman_guide", #"{"profile":"fixture","model":"model"}"#)
    #expect(guide["structuredContent"]?["data"]?["guide"]?["summary"] == .string("改写用途"))
    _ = try await call("keyman_manage_profile", #"{"action":"add","document":{"alias":"destination","name":"Destination"},"dryRun":false}"#)
    _ = try await call("keyman_manage_model", #"{"action":"move","profile":"fixture","model":"model","destinationProfile":"destination","document":{},"dryRun":false}"#)
    #expect(try await config.load().profiles.first { $0.alias == "fixture" }?.models.isEmpty == true)
    _ = try await call("keyman_manage_model", #"{"action":"move","profile":"destination","model":"model","destinationProfile":"fixture","document":{},"dryRun":false}"#)
    _ = try await call("keyman_manage_profile", #"{"action":"delete","profile":"destination","dryRun":false}"#)
    _ = try await call("keyman_manage_profile", #"{"action":"update","profile":"fixture","document":{"alias":"renamed"},"dryRun":false}"#)
    let id = try #require(try await config.load().profiles.first?.id)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("synthetic-mcp-secret-1234".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    _ = try await adapter.call(name: "keyman_credential_set_file", arguments: ["profile": .string("renamed"), "path": .string(file.path), "dryRun": .bool(false)])
    #expect(try await keys.load(for: id) == "synthetic-mcp-secret-1234")
    let status = try await call("keyman_credential_status", #"{"profile":"renamed"}"#)
    #expect(String(decoding: try JSONEncoder().encode(status), as: UTF8.self).contains("1234"))
    _ = try await call("keyman_manage_model", #"{"action":"disable","profile":"renamed","model":"model","dryRun":false}"#)
    #expect(try await config.load().profiles[0].models[0].isEnabled == false)
    _ = try await call("keyman_manage_model", #"{"action":"enable","profile":"renamed","model":"model","dryRun":false}"#)
    _ = try await call("keyman_manage_model", #"{"action":"delete","profile":"renamed","model":"model","dryRun":false}"#)
    _ = try await call("keyman_manage_endpoint", #"{"action":"delete","profile":"renamed","endpoint":"api","dryRun":false}"#)
    _ = try await call("keyman_credential_clear", #"{"profile":"renamed","dryRun":false}"#)
    _ = try await call("keyman_manage_profile", #"{"action":"delete","profile":"renamed","dryRun":false}"#)
    #expect(try await config.load().profiles.isEmpty)
}

@Test func mcpDiscoveryAndGuidesDoNotReadKeychain() async throws {
    let config = InMemoryConfigurationStore(.init(profiles: [try mcpProfile()]))
    let adapter = MCPToolAdapter(application: mcpApp(config: config, keys: FailingCredentialStore()))
    for (name, arguments) in [
        ("keyman_accounts", [:]), ("keyman_catalog", [:]),
        ("keyman_profile", ["profile": JSONValue.string("account")]),
        ("keyman_models", ["profile": .string("account")]),
        ("keyman_endpoints", ["profile": .string("account")]),
        ("keyman_guide", ["profile": .string("account"), "model": .string("text")]),
        ("keyman_preflight", ["profile": .string("account"), "model": .string("text"), "body": .object(["prompt": .string("fixture")])])
    ] {
        let result = try await adapter.call(name: name, arguments: arguments)
        #expect(result["isError"] == .bool(false))
    }
}

private actor MCPCountingCaller: ModelCalling {
    var calls = 0
    var queries = 0
    var cancelled = false
    let slow: Bool
    init(slow: Bool = false) { self.slow = slow }
    func call(profileAlias: String, modelAlias: String, body: Data, policyOverride: OutputPolicy?) async throws -> CallResponse {
        calls += 1
        if slow {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled = true; throw error }
        }
        return .init(statusCode: 200, headers: [:], body: Data(#"{"result":"fixture"}"#.utf8), isAsync: false)
    }
    func query(profileAlias: String, modelAlias: String, taskID: String) async throws -> CallResponse {
        queries += 1
        return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), isAsync: true,
            task: TaskProgress(id: taskID, status: "running", terminal: false, succeeded: false, queryCommand: ["keyman", "task", "account", "text", taskID]), generationRequestSent: false)
    }
}

@Test func mcpCallsRequireAuthorizationAndPreflightAndPendingTasksNeverResubmit() async throws {
    let config = InMemoryConfigurationStore(.init(profiles: [try mcpProfile()]))
    let caller = MCPCountingCaller(); let adapter = MCPToolAdapter(application: mcpApp(config: config, caller: caller))
    let args: [String: JSONValue] = ["profile": .string("account"), "model": .string("text"), "body": .object(["prompt": .string("hello")])]
    let denied = try await adapter.call(name: "keyman_call", arguments: args.merging(["authorized": .bool(false)]) { _, b in b })
    #expect(denied["isError"] == .bool(true)); #expect(await caller.calls == 0)
    let invalid = try await adapter.call(name: "keyman_call", arguments: args.merging(["authorized": .bool(true), "body": .object([:])]) { _, b in b })
    #expect(invalid["isError"] == .bool(true)); #expect(await caller.calls == 0)
    let valid = try await adapter.call(name: "keyman_call", arguments: args.merging(["authorized": .bool(true)]) { _, b in b })
    #expect(valid["isError"] == .bool(false)); #expect(await caller.calls == 1)
    let task = try await adapter.call(name: "keyman_task", arguments: ["profile": .string("account"), "model": .string("text"), "taskId": .string("existing")])
    #expect(task["isError"] == .bool(false))
    #expect(task["structuredContent"]?["state"] == .string("pending"))
    #expect(task["structuredContent"]?["automaticRetryAllowed"] == .bool(false))
    #expect(await caller.calls == 1); #expect(await caller.queries == 1)
}

@Test func mcpCancellationLeavesReaderResponsiveAndDoesNotRetry() async throws {
    let caller = MCPCountingCaller(slow: true), messages = MCPMessages()
    let server = MCPServer(application: mcpApp(config: .init(.init(profiles: [try mcpProfile()])), caller: caller)) { messages.append($0) }
    await mcpReady(server)
    await mcpSend(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"keyman_call","arguments":{"profile":"account","model":"text","body":{"prompt":"hello"},"authorized":true}}}"#)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await caller.calls == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    await mcpSend(server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
    #expect(messages.messages.last?["id"] == .integer(2))
    await mcpSend(server, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#)
    while await !caller.cancelled, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await caller.calls == 1); #expect(await caller.cancelled)
    #expect(!messages.messages.contains { $0["id"] == .integer(1) })
    await server.shutdown()
}

@Test func mcpWatermarkPreviewValidatesCapabilityAndPreservesStrictPolicy() async throws {
    let config = InMemoryConfigurationStore(.init(profiles: [try mcpProfile()]))
    let adapter = MCPToolAdapter(application: mcpApp(config: config))
    let args: [String: JSONValue] = ["profile": .string("account"), "model": .string("text"),
        "document": .object(["disposition": .string("configurable"), "evidence": .string("fixture")])]
    let invalid = try await adapter.call(name: "keyman_watermark_config", arguments: args)
    #expect(invalid["isError"] == .bool(true))
    let valid = args.merging(["document": .object(["disposition": .string("unknown"), "evidence": .string("not researched")])]) { _, b in b }
    _ = try await adapter.call(name: "keyman_watermark_config", arguments: valid)
    #expect(try await config.load().profiles[0].models[0].watermarkCapability == nil)
    _ = try await adapter.call(name: "keyman_watermark_config", arguments: valid.merging(["dryRun": .bool(false)]) { _, b in b })
    #expect(try await config.load().profiles[0].models[0].watermarkCapability?.disposition == .unknown)
    _ = try await adapter.call(name: "keyman_policy_set", arguments: ["policy": .string("provider-default")])
    #expect(try await config.load().outputPolicy == .noVisibleWatermark)
}
