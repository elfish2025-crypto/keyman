import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

struct ModelGuideCLITests {
    @Test func discoveryAndExampleToPreflightWorkWithDeniedKeychain() async throws {
        var profile = try ManagementDocuments.profile(Data(#"{"alias":"local","name":"Local Test","provider":"custom-rest","authentication":{"headerName":"Authorization","prefix":"Bearer","environmentVariable":"TEST_API_KEY"},"endpoints":[{"alias":"default","name":"Test","baseURL":"http://127.0.0.1:9999/v1"}]}"#.utf8))
        var model = try ManagementDocuments.model(Data(#"{"alias":"text","name":"Text","modelID":"text-v1","modality":"text","status":"declared","callTemplate":{"endpointAlias":"default","path":"/chat/completions","modelIDBodyField":"model"},"usageGuide":{"summary":"写作与摘要","inputs":"messages 文本消息","outputs":"文本回复","requestExample":{"messages":[{"role":"user","content":"Hello"}]}}}"#.utf8))
        let binding = WatermarkPolicy.fingerprint(profile: profile, model: model)
        model.usageGuide?.contractFingerprint = binding
        profile.models = [model]
        let config = InMemoryConfigurationStore(.init(profiles: [profile]))
        let app = CLIApplication(configurationStore: config, credentialStore: FailingCredentialStore(), modelCaller: StubModelCaller(), commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
        let catalog = await app.execute(arguments: ["catalog", "摘要", "--json"], stdin: { Data() })
        #expect(catalog.exitCode == 0)
        #expect(try JSONDecoder().decode([AccountCatalogEntry].self, from: catalog.stdout).first?.models.first?.requestReady == true)
        let guide = await app.execute(arguments: ["guide", "local", "text", "--json"], stdin: { Data() })
        #expect(guide.exitCode == 0)
        let packet = try JSONDecoder().decode(ModelUsagePacket.self, from: guide.stdout)
        #expect(!packet.credentialRead && !packet.providerAccessVerified)
        let example = await app.execute(arguments: ["example", "local", "text"], stdin: { Data() })
        #expect(example.exitCode == 0)
        let checked = await app.execute(arguments: ["preflight", "local", "text", "--body-stdin"], stdin: { example.stdout })
        #expect(checked.exitCode == 0)
        let response = try JSONSerialization.jsonObject(with: checked.stdout) as? [String: Any]
        #expect(response?["credentialRead"] as? Bool == false)
        #expect((response?["body"] as? [String: Any])?["model"] as? String == "text-v1")
    }

    @Test func sourceMigrationRequiresExplicitFreshnessAssertion() throws {
        expectThrows { try CLIParser.parse(["vault", "migrate", "--source", "/some/directory"]) }
        #expect(try CLIParser.parse(["vault", "migrate", "--source", "/some/directory", "--source-current", "--dry-run"]) == .migrateVault(source: "/some/directory", dryRun: true))
        #expect(try CLIParser.parse(["vault", "unlock"]) == .vaultStatus(unlock: true))
        #expect(try CLIParser.parse(["catalog", "文字", "配音", "--json"]) == .catalog(query: "文字 配音", json: true))
    }
}
