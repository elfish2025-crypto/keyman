import Foundation
import Testing
@testable import KeymanCore

extension CallTemplate {
    static let httpFixture = CallTemplate(
        endpointAlias: "default",
        method: .post,
        path: "/images/generations",
        modelIDBodyField: "model",
        staticHeaders: [:],
        requestFields: ["prompt", "size"],
        isAsync: false
    )
}

extension ModelRecord {
    static let seedreamFixture = ModelRecord(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        alias: "seedream-5-pro",
        name: "Doubao Seedream 5.0 Pro",
        modelID: "doubao-seedream-5-0-pro-260628",
        modality: .image,
        status: .declared,
        callTemplate: .httpFixture,
        sourceFile: nil,
        lastVerifiedAt: nil
    )

    static func fixture(
        alias: String,
        modelID: String?,
        status: ModelStatus,
        callTemplate: CallTemplate?
    ) -> ModelRecord {
        ModelRecord(
            id: UUID(),
            alias: alias,
            name: alias,
            modelID: modelID,
            modality: .other,
            status: status,
            callTemplate: callTemplate,
            sourceFile: nil,
            lastVerifiedAt: nil
        )
    }
}

extension ProviderProfile {
    static let bailianFixture = ProviderProfile(
        id: UUID(),
        alias: "example-workspace",
        name: "example-workspace",
        provider: .alibabaBailian,
        project: nil,
        region: "cn-beijing",
        workspaceName: "example-workspace",
        workspaceID: "workspace",
        endpoints: [
            .init(
                id: UUID(),
                alias: "openai",
                name: "OpenAI Compatible",
                baseURL: URL(
                    string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
                )!
            )
        ],
        authentication: .init(
            headerName: "Authorization",
            prefix: "Bearer",
            environmentVariable: "DASHSCOPE_API_KEY"
        ),
        notes: nil,
        sourceFiles: [],
        models: [],
        lastTestedAt: nil,
        lastTestSucceeded: nil
    )

    static func fixture(
        alias: String,
        models: [ModelRecord] = []
    ) -> ProviderProfile {
        ProviderProfile(
            id: UUID(),
            alias: alias,
            name: alias,
            provider: .volcengineArk,
            project: "default",
            region: "cn-beijing",
            workspaceName: nil,
            workspaceID: nil,
            endpoints: [
                .init(
                    id: UUID(),
                    alias: "default",
                    name: "Ark",
                    baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
                )
            ],
            authentication: .init(
                headerName: "Authorization",
                prefix: "Bearer",
                environmentVariable: "ARK_API_KEY"
            ),
            notes: nil,
            sourceFiles: [],
            models: models,
            lastTestedAt: nil,
            lastTestSucceeded: nil
        )
    }

    func withNewID() -> ProviderProfile {
        ProviderProfile(
            id: UUID(),
            alias: alias,
            name: name,
            provider: provider,
            project: project,
            region: region,
            workspaceName: workspaceName,
            workspaceID: workspaceID,
            endpoints: endpoints,
            authentication: authentication,
            notes: notes,
            sourceFiles: sourceFiles,
            models: models,
            lastTestedAt: lastTestedAt,
            lastTestSucceeded: lastTestSucceeded
        )
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

func expectThrowsAsync<T>(
    _ expression: () async throws -> T
) async {
    do {
        _ = try await expression()
        Issue.record("Expected error")
    } catch {}
}

actor InMemoryConfigurationStore: ConfigurationStoring {
    private var value: KeymanConfiguration
    private(set) var saveCount = 0

    init(_ value: KeymanConfiguration = .init(profiles: [])) {
        self.value = value
    }

    func load() async throws -> KeymanConfiguration { value }

    func save(_ configuration: KeymanConfiguration) async throws {
        try ConfigurationValidator.validate(configuration)
        value = configuration
        saveCount += 1
    }
}

final class RecordingKeychainBackend: KeychainBackend, @unchecked Sendable {
    var values: [String: Data] = [:]
    var lastService: String?
    var lastAccount: String?

    func write(service: String, account: String, data: Data) {
        lastService = service
        lastAccount = account
        values["\(service)|\(account)"] = data
    }

    func read(service: String, account: String) -> Data? {
        lastService = service
        lastAccount = account
        return values["\(service)|\(account)"]
    }

    func delete(service: String, account: String) {
        values["\(service)|\(account)"] = nil
    }
}

actor RecordingHTTPTransport: HTTPTransporting {
    let response: HTTPResponse
    private(set) var lastRequest: URLRequest?

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lastRequest = request
        return response
    }
}
