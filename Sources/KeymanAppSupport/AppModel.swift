import Foundation
import Observation
import KeymanCore

public enum CredentialAvailability: Sendable { case loading, available, missing, unavailable }

@MainActor
@Observable
public final class AppModel {
    public private(set) var configuration: KeymanConfiguration
    public private(set) var credentialSuffixes: [UUID: String]
    public private(set) var credentialAvailability: [UUID: CredentialAvailability] = [:]
    public private(set) var isManaging = false
    public private(set) var profileTestResults: [UUID: ProfileTestResult]
    public private(set) var modelTestResults: [UUID: String] = [:]
    public private(set) var testingModelID: UUID?
    public var selectedProfileID: UUID?
    public var presentedError: String?
    public private(set) var mediaInspections: [MediaInspection] = []
    public private(set) var checkingMedia = false
    public private(set) var vaultStatus: CredentialVaultStatus?
    public private(set) var vaultMigrationReport: VaultMigrationReport?

    private let configurationStore: any ConfigurationStoring
    private let credentialStore: any CredentialStoring
    private let importer: any LegacyImporting
    private let profileTester: (any ProfileTesting)?
    private let modelCaller: (any ModelCalling)?
    private var reloadID = UUID()
    public private(set) var confirmedBillableModelID: UUID?

    public init(
        configurationStore: any ConfigurationStoring,
        credentialStore: any CredentialStoring,
        importer: any LegacyImporting,
        modelCaller: (any ModelCalling)? = nil,
        profileTester: (any ProfileTesting)? = nil
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.importer = importer
        self.modelCaller = modelCaller
        self.profileTester = profileTester
        self.configuration = KeymanConfiguration(profiles: [])
        self.credentialSuffixes = [:]
        self.profileTestResults = [:]
    }

    public var canStartBillableTest: Bool { confirmedBillableModelID != nil }

    public func requiresBillingConfirmation(for model: ModelRecord) -> Bool {
        model.status == .declared || model.status == .verified
    }

    public func confirmBillableTest(modelID: UUID) {
        confirmedBillableModelID = modelID
    }

    public func clearBillableConfirmation() {
        confirmedBillableModelID = nil
    }

    public func testModel(
        profileAlias: String,
        model: ModelRecord,
        body: Data,
        expectedProfile: ProviderProfile? = nil
    ) async throws -> CallResponse {
        guard confirmedBillableModelID == model.id else {
            throw KeymanError.invalidRequest("收费模型测试尚未确认")
        }
        guard testingModelID == nil else {
            throw KeymanError.invalidRequest("已有模型测试正在进行，请等待结果。")
        }
        guard let modelCaller else {
            throw KeymanError.invalidRequest("当前运行环境未配置模型调用器")
        }
        testingModelID = model.id
        presentedError = nil
        modelTestResults[model.id] = nil
        // Consume confirmation before the first await to prevent duplicate calls.
        clearBillableConfirmation()
        defer { testingModelID = nil }
        if let expectedProfile {
            let latest = try await configurationStore.load()
            guard latest.profiles.first(where: { $0.id == expectedProfile.id }) == expectedProfile,
                  expectedProfile.models.contains(model) else { throw KeymanError.configurationChanged }
        }
        let response = try await modelCaller.call(
            profileAlias: profileAlias,
            modelAlias: model.alias,
            body: body
        )
        if let verification = response.verification {
            modelTestResults[model.id] = verification.detail
            if !verification.deliverable { presentedError = verification.detail }
        } else {
            modelTestResults[model.id] = response.isAsync
                ? "任务已提交（HTTP \(response.statusCode)），需继续查询任务结果。"
                : "已收到模型响应（HTTP \(response.statusCode)）；未执行成品水印检查。"
        }
        return response
    }

    public func setOutputPolicy(_ policy: OutputPolicy) async throws {
        var next = try await configurationStore.load()
        let original = next
        next.outputPolicy = policy
        try await configurationStore.save(next, replacing: original)
        configuration = next
        presentedError = nil
    }

    public func queryTask(profile: ProviderProfile, model: ModelRecord, taskID: String) async throws -> CallResponse {
        guard let modelCaller else { throw KeymanError.invalidRequest("当前环境未配置模型调用器。") }
        let latest = try await configurationStore.load()
        guard latest.profiles.first(where: { $0.id == profile.id }) == profile else { throw KeymanError.configurationChanged }
        return try await modelCaller.query(profileAlias: profile.alias, modelAlias: model.alias, taskID: taskID)
    }

    public func inspectMedia(_ urls: [URL]) async {
        guard !checkingMedia else { return }
        checkingMedia = true
        defer { checkingMedia = false }
        mediaInspections = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            mediaInspections.append(await LocalMediaInspector().inspect(url))
            if access { url.stopAccessingSecurityScopedResource() }
        }
    }

    public func reload() async throws {
        let token = UUID(); reloadID = token
        configuration = try await configurationStore.load()
        let ids = Set(configuration.profiles.map(\.id))
        credentialSuffixes = credentialSuffixes.filter { ids.contains($0.key) }
        credentialAvailability = Dictionary(uniqueKeysWithValues: ids.map { ($0, .loading) })
        var firstError: Error?
        for profile in configuration.profiles {
            do {
                let suffix = try await credentialStore.maskedSuffix(for: profile.id)
                guard reloadID == token else { return }
                guard configuration.profiles.first(where: { $0.id == profile.id })?.credentialRevision == profile.credentialRevision else { continue }
                credentialSuffixes[profile.id] = suffix
                credentialAvailability[profile.id] = .available
            }
            catch KeymanError.keyMissing {
                guard reloadID == token else { return }
                guard configuration.profiles.first(where: { $0.id == profile.id })?.credentialRevision == profile.credentialRevision else { continue }
                credentialSuffixes[profile.id] = nil
                credentialAvailability[profile.id] = .missing
            }
            catch {
                guard reloadID == token else { return }
                guard configuration.profiles.contains(where: { $0.id == profile.id }) else { continue }
                credentialAvailability[profile.id] = .unavailable
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    public func readVaultStatus(unlock: Bool = false) async throws {
        guard let vault = credentialStore as? KeychainCredentialStore else { throw KeymanError.invalidRequest("当前环境未使用 macOS 钥匙串。") }
        let snapshot = try await configurationStore.load()
        let status = try await vault.vaultStatus(profileIDs: snapshot.profiles.map(\.id), interactive: unlock)
        guard try await configurationStore.load() == snapshot else { throw KeymanError.configurationChanged }
        vaultStatus = status
        reloadID = UUID()
        configuration = snapshot
        for entry in status.profiles {
            if entry.state == .stored {
                credentialSuffixes[entry.profileID] = entry.secretSuffix
                credentialAvailability[entry.profileID] = .available
            } else if entry.state == .cleared {
                credentialSuffixes[entry.profileID] = nil
                credentialAvailability[entry.profileID] = .missing
            }
        }
        presentedError = nil
    }

    public func migrateVault(sourceURL: URL? = nil) async throws {
        guard let vault = credentialStore as? KeychainCredentialStore else { throw KeymanError.invalidRequest("当前环境未使用 macOS 钥匙串。") }
        let preview = try sourceURL.map { try importer.preview(rootURL: $0) }
        try await managing {
            vaultMigrationReport = try await CredentialVaultCoordinator(configurationStore: configurationStore, credentialStore: vault).migrate(source: preview)
        }
        try await readVaultStatus()
    }

    public func saveProfile(_ profile: ProviderProfile, secret: String?, original: ProviderProfile? = nil) async throws {
        try await managing {
            let expected = original ?? configuration.profiles.first(where: { $0.id == profile.id })
            try await manager.saveProfile(profile, original: expected, secret: secret?.isEmpty == true ? nil : secret)
            if let secret, !secret.isEmpty {
                credentialSuffixes[profile.id] = String(secret.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4))
                credentialAvailability[profile.id] = .available
            } else if expected == nil { credentialAvailability[profile.id] = .missing }
        }
    }

    public func deleteProfile(_ id: UUID, original: ProviderProfile? = nil) async throws {
        try await managing {
            let profile = try original ?? localProfile(id)
            try await manager.deleteProfile(profile.alias, original: profile)
            credentialSuffixes[id] = nil
            credentialAvailability[id] = nil
        }
    }

    public func setProfileEnabled(_ id: UUID, enabled: Bool) async throws {
        let original = try localProfile(id)
        var draft = original; draft.isEnabled = enabled
        try await saveProfile(draft, secret: nil, original: original)
    }

    public func replaceKey(profileID: UUID, secret: String?, original: ProviderProfile? = nil) async throws {
        try await managing {
            let profile = try original ?? localProfile(profileID)
            try await manager.setCredential(profile.alias, secret: secret, expectedProfile: profile)
            profileTestResults[profileID] = nil
            for record in profile.models { modelTestResults[record.id] = nil }
            credentialSuffixes[profileID] = secret.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4)) }
            credentialAvailability[profileID] = secret == nil ? .missing : .available
        }
    }

    public func addOrUpdateModel(_ model: ModelRecord, profileID: UUID,
                                 expectedProfile: ProviderProfile? = nil, original: ModelRecord? = nil, confirmUsageExample: Bool = false) async throws {
        try await managing {
            let profile = try expectedProfile ?? localProfile(profileID)
            let expected = original ?? profile.models.first(where: { $0.id == model.id })
            try await manager.saveModel(model, profileAlias: profile.alias, original: expected, expectedProfile: profile, confirmUsageExample: confirmUsageExample)
        }
    }

    public func deleteModel(_ model: ModelRecord, profileID: UUID) async throws {
        try await managing {
            let profile = try localProfile(profileID)
            guard profile.models.contains(model) else { throw KeymanError.configurationChanged }
            try await manager.deleteModel(model.alias, profileAlias: profile.alias, expectedProfile: profile)
        }
    }

    public func setModelEnabled(_ model: ModelRecord, profileID: UUID, enabled: Bool) async throws {
        var draft = model; draft.isEnabled = enabled
        try await addOrUpdateModel(draft, profileID: profileID, original: model)
    }

    public func importPreview(rootURL: URL) throws -> ImportPreview {
        try importer.preview(rootURL: rootURL)
    }

    public func commitImport(_ preview: ImportPreview) async throws {
        try await managing {
            try await LegacyImportCoordinator(
                configurationStore: configurationStore,
                credentialStore: credentialStore
            ).commit(preview)
        }
        try await reload()
    }

    public func testProfile(_ profile: ProviderProfile) async throws {
        guard let profileTester else {
            throw KeymanError.invalidRequest("当前运行环境未配置测试器")
        }
        profileTestResults[profile.id] = try await profileTester.test(
            profileAlias: profile.alias
        )
    }

    public func credentialLabel(_ id: UUID) -> String {
        switch credentialAvailability[id] ?? .loading {
        case .loading: "正在读取 Key…"
        case .available: "Key ····\(credentialSuffixes[id] ?? "")"
        case .missing: "未配置 Key"
        case .unavailable: "Key 待授权或读取失败"
        }
    }

    private var manager: KeymanManager {
        .init(configurationStore: configurationStore, credentialStore: credentialStore)
    }

    private func localProfile(_ id: UUID) throws -> ProviderProfile {
        guard let value = configuration.profiles.first(where: { $0.id == id }) else { throw KeymanError.profileNotFound(id.uuidString) }
        return value
    }

    private func managing(_ operation: () async throws -> Void) async throws {
        guard !isManaging else { throw KeymanError.invalidRequest("正在保存，请等待本次操作完成。") }
        isManaging = true
        defer { isManaging = false }
        let before = configuration
        try await operation()
        configuration = try await configurationStore.load()
        for previous in before.profiles {
            if configuration.profiles.first(where: { $0.id == previous.id }) != previous {
                profileTestResults[previous.id] = nil
                for record in previous.models { modelTestResults[record.id] = nil }
            }
        }
        presentedError = nil
    }
}
