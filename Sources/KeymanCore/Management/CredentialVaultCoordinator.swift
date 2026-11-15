import Foundation

public struct VaultMigrationReport: Codable, Sendable {
    public var dryRun: Bool
    public var migratedAliases: [String]
    public var missingAliases: [String]
    public var source: String
    public var keychainRead: Bool
    public var sourceCredentialsRead: Bool
    public var legacyBackupsRetained = true
    public var networkRequest = false
}

public struct CredentialVaultCoordinator: Sendable {
    private let configurations: any ConfigurationStoring
    private let credentials: KeychainCredentialStore

    public init(configurationStore: any ConfigurationStoring, credentialStore: KeychainCredentialStore) {
        configurations = configurationStore; credentials = credentialStore
    }

    public func migrate(source: ImportPreview? = nil, dryRun: Bool = false) async throws -> VaultMigrationReport {
        let current = try await configurations.load()
        var sourceValues: [UUID: String]? = source == nil ? nil : [:]
        if let source {
            for item in source.profiles {
                let matches = current.profiles.filter { $0.alias == item.profile.alias || $0.previousAliases.contains(item.profile.alias) }
                guard matches.count <= 1 else { throw KeymanError.configurationChanged }
                guard let profile = matches.first else { continue }
                guard profile.provider == item.profile.provider,
                      profile.authentication.environmentVariable == item.profile.authentication.environmentVariable,
                      profile.workspaceID == item.profile.workspaceID else {
                    throw KeymanError.invalidRequest("来源与账号 \(profile.alias) 的凭证类型或工作空间不符，迁移已停止。")
                }
                guard let secret = item.secret, !secret.isEmpty else { throw KeymanError.importInvalid("来源中的账号 \(item.profile.alias) 缺少 Key。") }
                if let prior = sourceValues?[profile.id], prior != secret { throw KeymanError.importInvalid("同一账号存在多个不同的来源 Key。") }
                sourceValues?[profile.id] = secret
            }
        }
        let targets = current.profiles.filter { sourceValues == nil || sourceValues?[$0.id] != nil }
        guard !targets.isEmpty else { throw KeymanError.invalidRequest("没有与现有账号匹配的待迁移凭证。") }
        let sourceLabel = source == nil ? "existing-keychain" : "user-confirmed-source-directory"
        if dryRun {
            return .init(dryRun: true, migratedAliases: targets.map(\.alias), missingAliases: [], source: sourceLabel, keychainRead: false, sourceCredentialsRead: source != nil)
        }
        let values = sourceValues
        return try await configurations.withCredentialMutation {
            guard try await configurations.load() == current else { throw KeymanError.configurationChanged }
            let migration = try await credentials.prepareMigration(profileIDs: targets.map(\.id), source: values)
            guard try await configurations.load() == current else { throw KeymanError.configurationChanged }
            if !migration.migratedIDs.isEmpty {
                var next = current
                for p in next.profiles.indices where migration.migratedIDs.contains(next.profiles[p].id) {
                    next.profiles[p].credentialRevision += 1
                    next.profiles[p].usesCredentialVault = true
                }
                try await credentials.commitMigration(migration)
                do { try await configurations.save(next, replacing: current) }
                catch {
                    do { try await credentials.rollbackMigration(migration) }
                    catch { throw KeymanError.invalidRequest("迁移期间配置未保存，凭证库恢复也未完成；原钥匙串条目仍保留，请重新核对。") }
                    throw error
                }
            }
            return .init(dryRun: false,
                migratedAliases: targets.filter { migration.migratedIDs.contains($0.id) }.map(\.alias),
                missingAliases: targets.filter { migration.missingIDs.contains($0.id) }.map(\.alias),
                source: sourceLabel, keychainRead: true, sourceCredentialsRead: source != nil)
        }
    }
}
