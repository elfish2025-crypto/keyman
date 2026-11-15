import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanAppSupport

actor InMemoryConfigurationStore: ConfigurationStoring {
    private var value: KeymanConfiguration

    init(_ value: KeymanConfiguration = .init(profiles: [])) {
        self.value = value
    }

    func load() async throws -> KeymanConfiguration { value }
    func save(_ configuration: KeymanConfiguration) async throws { value = configuration }
}

actor InMemoryCredentialStore: CredentialStoring {
    private var values: [UUID: String] = [:]

    func save(_ secret: String, for profileID: UUID) async {
        values[profileID] = secret
    }

    func load(for profileID: UUID) async throws -> String {
        guard let value = values[profileID] else { throw KeymanError.keyMissing }
        return value
    }

    func delete(for profileID: UUID) async {
        values.removeValue(forKey: profileID)
    }

    func maskedSuffix(for profileID: UUID) async throws -> String {
        String(try await load(for: profileID).suffix(4))
    }
}

extension ModelRecord {
    static let seedreamFixture = ModelRecord(
        id: UUID(),
        alias: "seedream-5-pro",
        name: "Doubao Seedream 5.0 Pro",
        modelID: "doubao-seedream-5-0-pro-260628",
        modality: .image,
        status: .declared,
        callTemplate: .init(
            endpointAlias: "default",
            method: .post,
            path: "/images/generations",
            modelIDBodyField: "model",
            staticHeaders: [:],
            requestFields: ["prompt", "size", "watermark"],
            isAsync: false
        ),
        sourceFile: nil,
        lastVerifiedAt: nil
    )
}

@MainActor
func expectThrowsAsync<T>(
    _ expression: @MainActor () async throws -> T
) async {
    do {
        _ = try await expression()
        Issue.record("Expected error")
    } catch {}
}

actor RecordingModelCaller: ModelCalling {
    private(set) var callCount = 0

    func call(
        profileAlias: String,
        modelAlias: String,
        body: Data,
        policyOverride: OutputPolicy?
    ) async throws -> CallResponse {
        callCount += 1
        return .init(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"data":[]}"#.utf8),
            isAsync: false
        )
    }
}
