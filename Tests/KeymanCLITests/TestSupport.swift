import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

actor InMemoryConfigurationStore: ConfigurationStoring {
    private var value: KeymanConfiguration
    private(set) var saveCount = 0

    init(_ value: KeymanConfiguration = .init(profiles: [])) {
        self.value = value
    }

    func load() async throws -> KeymanConfiguration { value }
    func save(_ configuration: KeymanConfiguration) async throws {
        value = configuration
        saveCount += 1
    }
}

actor FailingCredentialStore: CredentialStoring {
    func save(_ secret: String, for profileID: UUID) async throws {
        throw KeymanError.keychainDenied
    }
    func load(for profileID: UUID) async throws -> String {
        throw KeymanError.keychainDenied
    }
    func delete(for profileID: UUID) async throws {
        throw KeymanError.keychainDenied
    }
    func maskedSuffix(for profileID: UUID) async throws -> String {
        throw KeymanError.keychainDenied
    }
}

struct StubModelCaller: ModelCalling {
    var response = CallResponse(statusCode: 200, headers: [:], body: Data("{}".utf8), isAsync: false)
    func call(profileAlias: String, modelAlias: String, body: Data, policyOverride: OutputPolicy?) async throws -> CallResponse {
        response
    }
}

struct StubCommandRunner: CommandRunning {
    var result = CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
    func run(
        command: [String],
        additionalEnvironment: [String: String]
    ) async throws -> CommandResult {
        result
    }
}

struct StubLegacyImporter: LegacyImporting {
    func preview(rootURL: URL) throws -> ImportPreview {
        let profile = ProviderProfile(
            id: UUID(),
            alias: "preview-profile",
            name: "Preview Profile",
            provider: .customREST,
            project: nil,
            region: nil,
            workspaceName: nil,
            workspaceID: nil,
            endpoints: [],
            authentication: .init(
                headerName: "Authorization",
                prefix: "Bearer",
                environmentVariable: "PREVIEW_API_KEY"
            ),
            notes: nil,
            sourceFiles: [],
            models: [],
            lastTestedAt: nil,
            lastTestSucceeded: nil
        )
        return ImportPreview(profiles: [
            ImportedProfilePreview(
                profile: profile,
                secret: "unit-test-import-credential",
                secretSuffix: "tial"
            )
        ])
    }
}

func expectThrows<T>(
    _ expression: () throws -> T
) {
    do {
        _ = try expression()
        Issue.record("Expected error")
    } catch {}
}
