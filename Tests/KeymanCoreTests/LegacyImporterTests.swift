import Foundation
import Testing
@testable import KeymanCore

@Test
func testArkDeclaredModelsAndSeedreamIDAreImported() throws {
    let root = try fixtureRoot()
    let before = try snapshotFiles(root)

    let preview = try LegacyImporter().preview(rootURL: root)
    let profile = try #require(
        preview.profiles.first(where: { $0.profile.alias == "example-ark" })
    )
    let seedream = try #require(
        profile.profile.models.first(where: { $0.alias == "seedream-5-pro" })
    )

    #expect(profile.profile.models.count == 5)
    #expect(seedream.status == .declared)
    #expect(seedream.modelID == "doubao-seedream-5-0-pro-260628")
    let after = try snapshotFiles(root)
    #expect(before == after)
}

@Test
func testBailianDocumentationModelsRemainCandidates() throws {
    let preview = try LegacyImporter().preview(rootURL: try fixtureRoot())
    let profile = try #require(
        preview.profiles.first(where: { $0.profile.provider == .alibabaBailian })
    )

    #expect(profile.profile.models.allSatisfy { $0.status == .candidate })
    #expect(profile.secretSuffix == "tial")
}

@Test
func testBailianAcceptsSchemelessApiHostAndNonASCIIDescription() throws {
    // Mirrors the real 阿里百炼 account.csv shape: apiHost without an
    // `https://` scheme and a non-ASCII description that the basic slug()
    // cannot derive a stable alias from.
    let root = try makeTempImportRoot(
        bailianCSV: """
        id,6375149
        apiKey,unit-test-import-credential
        apiHost,ws-unit-test-region.cn-beijing.maas.aliyunces.com
        openAiCompatible,https://ws-unit-test-region.cn-beijing.maas.aliyunces.com/compatible-mode/v1
        dashScope,https://ws-unit-test-region.cn-beijing.maas.aliyunces.com/api/v1
        description,语音模型
        workspaceName,example-workspace
        workspaceId,ws-unit-test-region

        """
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let preview = try LegacyImporter().preview(rootURL: root)
    let profile = try #require(
        preview.profiles.first(where: { $0.profile.provider == .alibabaBailian })
    )

    #expect(profile.profile.alias != "imported-profile")
    #expect(profile.profile.alias == "ws-unit-test-region")
    let apiHost = try #require(
        profile.profile.endpoints.first(where: { $0.alias == "api-host" })
    )
    #expect(apiHost.baseURL.scheme == "https")
    #expect(apiHost.baseURL.host == "ws-unit-test-region.cn-beijing.maas.aliyunces.com")
    #expect(profile.secretSuffix == "tial")
}

@Test
func testBailianRejectsEmptySlugFallback() throws {
    // When the description is non-ASCII AND no workspaceId is present, the
    // importer falls back to the generic alias rather than crashing.
    let root = try makeTempImportRoot(
        bailianCSV: """
        id,6375149
        apiKey,unit-test-import-credential
        apiHost,https://workspace.cn-beijing.maas.aliyunces.com
        openAiCompatible,https://workspace.cn-beijing.maas.aliyunces.com/compatible-mode/v1
        dashScope,https://workspace.cn-beijing.maas.aliyunces.com/api/v1
        description,语音模型
        workspaceName,example-workspace
        workspaceId,

        """
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let preview = try LegacyImporter().preview(rootURL: root)
    let profile = try #require(
        preview.profiles.first(where: { $0.profile.provider == .alibabaBailian })
    )

    #expect(profile.profile.alias == "imported-profile")
}

@Test
func testCommitRollsBackKeychainWhenConfigSaveFails() async {
    let credentials = InMemoryCredentialStore()
    let coordinator = LegacyImportCoordinator(
        configurationStore: AlwaysFailingConfigurationStore(),
        credentialStore: credentials
    )
    let preview = try! LegacyImporter().preview(rootURL: fixtureRoot())

    await expectThrowsAsync { try await coordinator.commit(preview) }
    for item in preview.profiles {
        await expectThrowsAsync {
            _ = try await credentials.load(for: item.profile.id)
        }
    }
}

private actor AlwaysFailingConfigurationStore: ConfigurationStoring {
    func load() async throws -> KeymanConfiguration {
        .init(profiles: [])
    }

    func save(_ configuration: KeymanConfiguration) async throws {
        throw KeymanError.providerError(status: 0, message: "synthetic save failure")
    }
}

private func fixtureRoot() throws -> URL {
    let root = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("Legacy", isDirectory: true)
    return root
}

private func snapshotFiles(_ root: URL) throws -> [String: Data] {
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
    )
    var snapshot: [String: Data] = [:]
    for case let url as URL in enumerator where url.hasDirectoryPath == false {
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        snapshot[relative] = try Data(contentsOf: url)
    }
    return snapshot
}

/// Builds a temporary import root with a minimal Ark directory (enough to
/// satisfy `parseArk`) plus a caller-provided 阿里百炼/account.csv and a
/// single markdown file (required for `markdownFiles(in:)`).
private func makeTempImportRoot(bailianCSV: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyman-import-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let ark = root.appendingPathComponent("火山方舟", isDirectory: true)
    try FileManager.default.createDirectory(at: ark, withIntermediateDirectories: true)
    let arkAccount = """
    名称：Example-Ark
    API Key：unit-test-ark-credential
    所属项目：default
    状态：生效中

    Example-Ark（名称）开通模型：
    Doubao-Seedream-5.0-pro

    """
    try arkAccount.write(
        to: ark.appendingPathComponent("火山方舟 API key 管理+ Ark CLI.md"),
        atomically: true,
        encoding: .utf8
    )
    let arkGuide = """
    {
      "model": "doubao-seedream-5-0-pro-260628",
      "prompt": "test",
      "size": "2K"
    }
    """
    try arkGuide.write(
        to: ark.appendingPathComponent("火山方舟-seeddream API 调用指南.md"),
        atomically: true,
        encoding: .utf8
    )

    let bailian = root.appendingPathComponent("阿里百炼", isDirectory: true)
    try FileManager.default.createDirectory(at: bailian, withIntermediateDirectories: true)
    try bailianCSV.write(
        to: bailian.appendingPathComponent("account.csv"),
        atomically: true,
        encoding: .utf8
    )
    try "# voice synthesis example\n"
        .write(
            to: bailian.appendingPathComponent("调用示例-实时语音合成.md"),
            atomically: true,
            encoding: .utf8
        )
    return root
}

@Test
func testAllCredentialKindsAreImportedWithoutMixingProvidersOrDuplicatingGuideKeys() throws {
    let root = try makeTempImportRoot(bailianCSV: """
    apiKey,unit-test-bailian-secret
    apiHost,example.invalid
    openAiCompatible,https://example.invalid/openai
    dashScope,https://example.invalid/dashscope
    description,voice
    workspaceId,workspace-test
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let ark = root.appendingPathComponent("火山方舟")
    for filename in ["火山方舟-seeddream API 调用指南.md", "火山方舟-seedance API 调用指南.md"] {
        try "名称：example-workspace-API\nAPI Key：unit-test-shared-guide-key\nmodel: doubao-seedream-5-0-pro-260628\n"
            .write(to: ark.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }
    try """
    APP ID：
    1234567890
    Access Token：
    unit-test-speech-access
    Secret Key：
    unit-test-speech-secret
    名称：
    example-workspace
    API Key：
    unit-test-speech-api
    """.write(to: ark.appendingPathComponent("火山方舟-seedaudio1.0 API Kye 调用指南.md"), atomically: true, encoding: .utf8)
    try "名称:example-project\nKey ID:unit-test-id\nKey:unit-test-vidu-secret\n"
        .write(to: root.appendingPathComponent("阿里百炼/vidu-api kye.md"), atomically: true, encoding: .utf8)
    let before = try snapshotFiles(root)
    let preview = try LegacyImporter().preview(rootURL: root)
    #expect(preview.profiles.count == 7)
    let guide = try #require(preview.profiles.first { $0.profile.alias == "ark-example-workspace-api" })
    #expect(guide.profile.sourceFiles.count == 2)
    #expect(guide.profile.models.isEmpty)
    let voice = try #require(preview.profiles.first { $0.profile.alias == "volc-speech-api" })
    #expect(voice.profile.workspaceID == "1234567890")
    #expect(voice.secret == "unit-test-speech-api")
    #expect(preview.profiles.first { $0.profile.alias == "volc-speech-access-token" }?.secret == "unit-test-speech-access")
    #expect(preview.profiles.first { $0.profile.alias == "volc-speech-secret-key" }?.secret == "unit-test-speech-secret")
    let vidu = try #require(preview.profiles.first { $0.profile.alias == "vidu-example-project" })
    #expect(vidu.profile.provider == .customREST)
    #expect(vidu.secret == "unit-test-vidu-secret")
    let bailian = try #require(preview.profiles.first { $0.profile.provider == .alibabaBailian })
    #expect(!bailian.profile.sourceFiles.contains { $0.contains("vidu") })
    #expect(bailian.profile.sourceFiles.contains { $0.hasSuffix("account.csv") })
    let encoded = String(decoding: try JSONEncoder().encode(preview.profiles.map(\.profile)), as: UTF8.self)
    for item in preview.profiles { #expect(!encoded.contains(try #require(item.secret))) }
    #expect(try snapshotFiles(root) == before)
}

@Test
func testRepeatImportPreservesExistingModelsIDsAndOutputPolicy() async throws {
    let preview = try LegacyImporter().preview(rootURL: fixtureRoot())
    var existing = preview.profiles[0].profile
    existing.notes = "Keep this user edit"
    existing.models[0].status = .verified
    let original = KeymanConfiguration(profiles: [existing], outputPolicy: .providerDefault)
    let store = ImportTestConfigurationStore(original)
    let credentials = InMemoryCredentialStore()
    try await credentials.save(#require(preview.profiles[0].secret), for: existing.id)
    let coordinator = LegacyImportCoordinator(configurationStore: store, credentialStore: credentials)
    let first = try await coordinator.commit(preview)
    #expect(first.credentials.map(\.state) == [.matching, .added])
    let saved = try await store.load()
    #expect(saved.outputPolicy == .providerDefault)
    #expect(saved.profiles[0] == existing)
    let repeated = try LegacyImporter().preview(rootURL: fixtureRoot()) // Fresh UUIDs, same source.
    let second = try await coordinator.commit(repeated)
    #expect(second.credentials.allSatisfy { $0.state == .matching })
    #expect(try await store.load() == saved)
    #expect(await store.saveCount == 1)
}

@Test
func testConflictingCredentialStopsBeforeAnyWrites() async throws {
    let preview = try LegacyImporter().preview(rootURL: fixtureRoot())
    let existing = preview.profiles[1].profile
    let original = KeymanConfiguration(profiles: [existing])
    let store = ImportTestConfigurationStore(original)
    let credentials = InMemoryCredentialStore()
    await credentials.save("different-existing-key", for: existing.id)
    let coordinator = LegacyImportCoordinator(configurationStore: store, credentialStore: credentials)
    let check = try await coordinator.check(preview)
    #expect(check.credentials.map(\.state) == [.missingProfile, .differentCredential])
    await expectThrowsAsync { try await coordinator.commit(preview) }
    #expect(await store.saveCount == 0)
    #expect(try await credentials.load(for: existing.id) == "different-existing-key")
    await expectThrowsAsync { try await credentials.load(for: preview.profiles[0].profile.id) }
}

@Test
func testMissingCredentialIsRestoredWithoutReplacingExistingConfiguration() async throws {
    let preview = try LegacyImporter().preview(rootURL: fixtureRoot())
    let original = KeymanConfiguration(profiles: preview.profiles.map(\.profile), outputPolicy: .providerDefault)
    let store = ImportTestConfigurationStore(original)
    let credentials = InMemoryCredentialStore()
    let report = try await LegacyImportCoordinator(configurationStore: store, credentialStore: credentials).commit(preview)
    #expect(report.credentials.allSatisfy { $0.state == .restored })
    var expected = original
    for index in expected.profiles.indices { expected.profiles[index].credentialRevision += 1 }
    #expect(try await store.load() == expected)
    #expect(await store.saveCount == 1)
    for item in preview.profiles {
        #expect(try await credentials.load(for: item.profile.id) == item.secret)
    }
}

@Test
func testFailedMergeDoesNotDeletePreviouslyStoredCredentials() async throws {
    let preview = try LegacyImporter().preview(rootURL: fixtureRoot())
    let existing = preview.profiles[0]
    let store = ImportTestConfigurationStore(.init(profiles: [existing.profile]), failSave: true)
    let credentials = InMemoryCredentialStore()
    try await credentials.save(#require(existing.secret), for: existing.profile.id)
    let coordinator = LegacyImportCoordinator(configurationStore: store, credentialStore: credentials)
    await expectThrowsAsync { try await coordinator.commit(preview) }
    #expect(try await credentials.load(for: existing.profile.id) == existing.secret)
    await expectThrowsAsync { try await credentials.load(for: preview.profiles[1].profile.id) }
}

private actor ImportTestConfigurationStore: ConfigurationStoring {
    var value: KeymanConfiguration
    var failSave: Bool
    private(set) var saveCount = 0
    init(_ value: KeymanConfiguration, failSave: Bool = false) {
        self.value = value; self.failSave = failSave
    }
    func load() async throws -> KeymanConfiguration { value }
    func save(_ configuration: KeymanConfiguration) async throws {
        if failSave { throw KeymanError.invalidRequest("Synthetic failure") }
        value = configuration; saveCount += 1
    }
}

@Test
func testMiniMaxAccountImportsWithoutInventingModelConfiguration() throws {
    let root = try makeTempImportRoot(bailianCSV: """
    apiKey,unit-test-bailian-secret
    apiHost,example.invalid
    openAiCompatible,https://example.invalid/openai
    dashScope,https://example.invalid/dashscope
    description,voice
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("minimax")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "https://example.invalid/docs\n\n名称：example-project\nAPI Key：unit-test-minimax-secret\n"
        .write(to: directory.appendingPathComponent("MiniMax API key.md"), atomically: true, encoding: .utf8)
    let preview = try LegacyImporter().preview(rootURL: root)
    let item = try #require(preview.profiles.first { $0.profile.alias == "minimax-example-project" })
    #expect(item.secret == "unit-test-minimax-secret")
    #expect(item.profile.models.isEmpty)
    #expect(item.profile.endpoints.isEmpty)
    #expect(item.profile.provider == .customREST)
    #expect(item.profile.authentication.environmentVariable == "MINIMAX_API_KEY")
}
