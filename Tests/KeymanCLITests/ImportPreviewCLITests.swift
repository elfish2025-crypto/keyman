import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

@Test
func testParsesImportPreview() throws {
    #expect(
        try CLIParser.parse(["import-preview", "/tmp/api-material", "--json"]) ==
        .importPreview(path: "/tmp/api-material", json: true)
    )
}

@Test
func testImportPreviewDoesNotWriteConfigurationOrCredentialStore() async {
    let configuration = InMemoryConfigurationStore()
    let credentials = FailingCredentialStore()
    let app = CLIApplication(
        configurationStore: configuration,
        credentialStore: credentials,
        modelCaller: StubModelCaller(),
        commandRunner: StubCommandRunner(),
        legacyImporter: StubLegacyImporter()
    )

    let result = await app.execute(
        arguments: ["import-preview", "/tmp/api-material", "--json"],
        stdin: { Data() }
    )
    let saveCount = await configuration.saveCount

    #expect(result.exitCode == 0)
    #expect(saveCount == 0)
    #expect(!String(decoding: result.stdout, as: UTF8.self).contains("unit-test-import-credential"))
}

@Test
func testParsesImportCommit() throws {
    #expect(
        try CLIParser.parse(["import-commit", "/tmp/api-material", "--json"]) ==
        .importCommit(path: "/tmp/api-material", json: true)
    )
}

@Test
func testImportCommitWritesSecretToCredentialStoreAndConfigWithoutLeakingIt() async throws {
    let configuration = InMemoryConfigurationStore()
    let credentials = InMemoryCredentialStore()
    let app = CLIApplication(
        configurationStore: configuration,
        credentialStore: credentials,
        modelCaller: StubModelCaller(),
        commandRunner: StubCommandRunner(),
        legacyImporter: StubLegacyImporter()
    )

    let result = await app.execute(
        arguments: ["import-commit", "/tmp/api-material", "--json"],
        stdin: { Data() }
    )

    // Command succeeded and committed exactly one config save.
    #expect(result.exitCode == 0)
    let saveCount = await configuration.saveCount
    #expect(saveCount == 1)

    // The full secret never appears in stdout (only the last-4 suffix is allowed).
    let stdout = String(decoding: result.stdout, as: UTF8.self)
    #expect(!stdout.contains("unit-test-import-credential"))
    #expect(stdout.contains("tial"))

    // The secret was written to the credential store (not the config file).
    let savedConfig = try await configuration.load()
    let encoded = try JSONEncoder().encode(savedConfig)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("unit-test-import-credential"))
    #expect(savedConfig.profiles.count == 1)

    // The profile is reachable by alias and its credential is in the store.
    let profile = savedConfig.profiles.first
    #expect(profile?.alias == "preview-profile")
    if let profile {
        let loaded = try await credentials.load(for: profile.id)
        #expect(loaded == "unit-test-import-credential")
    }
}

@Test
func testImportCheckReportsMissingAndMatchingCredentialsWithoutWritesOrLeaks() async throws {
    #expect(try CLIParser.parse(["import-check", "/tmp/api", "--json"]) == .importCheck(path: "/tmp/api", json: true))
    let configuration = InMemoryConfigurationStore()
    let credentials = InMemoryCredentialStore()
    let app = CLIApplication(configurationStore: configuration, credentialStore: credentials,
        modelCaller: StubModelCaller(), commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    let before = await app.execute(arguments: ["import-check", "/tmp/api", "--json"], stdin: { Data() })
    #expect(before.exitCode == 1)
    #expect(await configuration.saveCount == 0)
    _ = await app.execute(arguments: ["import-commit", "/tmp/api", "--json"], stdin: { Data() })
    let after = await app.execute(arguments: ["import-check", "/tmp/api", "--json"], stdin: { Data() })
    let again = await app.execute(arguments: ["import-commit", "/tmp/api", "--json"], stdin: { Data() })
    #expect(after.exitCode == 0)
    #expect(again.exitCode == 0)
    #expect(await configuration.saveCount == 1)
    let stdout = String(decoding: after.stdout, as: UTF8.self)
    #expect(stdout.contains("matching"))
    #expect(!stdout.contains("unit-test-import-credential"))
    let report = try JSONDecoder().decode(ImportReport.self, from: after.stdout)
    #expect(report.networkRequest == false)
}

@Test
func testProfileMetadataCanBeReadWithoutCredentialAccess() async throws {
    #expect(try CLIParser.parse(["profile", "preview-profile", "--json"]) == .profile(profile: "preview-profile", json: true))
    let preview = try StubLegacyImporter().preview(rootURL: URL(fileURLWithPath: "/tmp/api"))
    let app = CLIApplication(configurationStore: InMemoryConfigurationStore(.init(profiles: preview.profiles.map(\.profile))),
        credentialStore: FailingCredentialStore(), modelCaller: StubModelCaller(),
        commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    let result = await app.execute(arguments: ["profile", "preview-profile", "--json"], stdin: { Data() })
    #expect(result.exitCode == 0)
    #expect(!String(decoding: result.stdout, as: UTF8.self).contains("unit-test-import-credential"))
}
