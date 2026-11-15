import Foundation
import Security
import LocalAuthentication

public protocol CredentialStoring: Sendable {
    func save(_ secret: String, for profileID: UUID) async throws
    func load(for profileID: UUID) async throws -> String
    func delete(for profileID: UUID) async throws
    func maskedSuffix(for profileID: UUID) async throws -> String
}

public protocol KeychainBackend: Sendable {
    func write(service: String, account: String, data: Data) throws
    func read(service: String, account: String) throws -> Data?
    func delete(service: String, account: String) throws
    func readWithoutInteraction(service: String, account: String) throws -> Data?
}

public extension KeychainBackend {
    func readWithoutInteraction(service: String, account: String) throws -> Data? {
        try read(service: service, account: account)
    }
}

public actor KeychainCredentialStore: CredentialStoring {
    /// Legacy items are read only until each account has been migrated.
    public static let service = "com.local.keyman.credentials"
    public static let vaultService = "com.local.keyman.vault"
    public static let vaultAccount = "credentials-v1"
    private let backend: any KeychainBackend
    private let configurations: (any ConfigurationStoring)?

    public init(backend: any KeychainBackend = SecurityKeychainBackend(), configurationStore: (any ConfigurationStoring)? = nil) {
        self.backend = backend
        self.configurations = configurationStore
    }

    public func save(_ secret: String, for profileID: UUID) async throws {
        guard !secret.isEmpty, secret.utf8.count <= 65_536 else {
            throw KeymanError.invalidRequest("API Key 不能为空")
        }
        var vault = try readVault(interactive: true) ?? CredentialVaultPayload()
        vault.secrets[profileID.uuidString] = secret
        vault.retiredLegacyAccounts.insert(profileID.uuidString)
        try writeVault(vault)
    }

    public func load(for profileID: UUID) async throws -> String {
        try await secret(for: profileID, interactive: true)
    }

    public func delete(for profileID: UUID) async throws {
        var vault = try readVault(interactive: true) ?? CredentialVaultPayload()
        // Clear the retained legacy backup as well; tombstones stop accidental resurrection.
        try backend.delete(service: Self.service, account: profileID.uuidString)
        vault.secrets[profileID.uuidString] = nil
        vault.retiredLegacyAccounts.insert(profileID.uuidString)
        try writeVault(vault)
    }

    public func maskedSuffix(for profileID: UUID) async throws -> String {
        // Window refreshes must not leave a hidden authorization request blocking this actor.
        let secret = try await secret(for: profileID, interactive: false)
        return secret.count > 4 ? String(secret.suffix(4)) : "••••"
    }

    private func secret(for id: UUID, interactive: Bool) async throws -> String {
        let migrated = try await configurations?.load().profiles.first(where: { $0.id == id })?.usesCredentialVault == true
        if let vault = try readVault(interactive: interactive) {
            if let value = vault.secrets[id.uuidString] { return value }
            if vault.retiredLegacyAccounts.contains(id.uuidString) { throw KeymanError.keyMissing }
        }
        // A missing/deleted vault must not resurrect retained pre-migration backups.
        if migrated { throw KeymanError.keyMissing }
        let data = try interactive ? backend.read(service: Self.service, account: id.uuidString)
            : backend.readWithoutInteraction(service: Self.service, account: id.uuidString)
        guard let data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw KeymanError.keyMissing }
        return value
    }

    private func readVault(interactive: Bool) throws -> CredentialVaultPayload? {
        let data = try interactive ? backend.read(service: Self.vaultService, account: Self.vaultAccount)
            : backend.readWithoutInteraction(service: Self.vaultService, account: Self.vaultAccount)
        guard let data else { return nil }
        guard let vault = try? JSONDecoder().decode(CredentialVaultPayload.self, from: data), vault.version == 1,
              vault.secrets.allSatisfy({ UUID(uuidString: $0.key) != nil && !$0.value.isEmpty && $0.value.utf8.count <= 65_536 }),
              vault.retiredLegacyAccounts.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw KeymanError.invalidRequest("统一凭证库格式异常；已停止读取，请检查备份，不会自动退回旧 Key。")
        }
        return vault
    }

    private func writeVault(_ vault: CredentialVaultPayload) throws {
        try backend.write(service: Self.vaultService, account: Self.vaultAccount, data: JSONEncoder().encode(vault))
    }

    /// One Keychain item is read; no legacy items are opened by status or unlock.
    public func vaultStatus(profileIDs: [UUID], interactive: Bool = false) async throws -> CredentialVaultStatus {
        let migrated = Set(try await configurations?.load().profiles.filter(\.usesCredentialVault).map(\.id) ?? [])
        let vault = try readVault(interactive: interactive)
        return .init(exists: vault != nil, profiles: profileIDs.map { id in
            let secret = vault?.secrets[id.uuidString]
            return .init(profileID: id, state: secret != nil ? .stored : (vault?.retiredLegacyAccounts.contains(id.uuidString) == true || migrated.contains(id) ? .cleared : .legacyOrMissing),
                secretSuffix: secret.map { $0.count > 4 ? String($0.suffix(4)) : "••••" })
        })
    }

    /// Called under the configuration store's cross-process credential lock.
    public func prepareMigration(profileIDs: [UUID], source: [UUID: String]?) throws -> CredentialVaultMigration {
        let previous = try readVault(interactive: true)
        var next = previous ?? CredentialVaultPayload()
        var moved: [UUID] = []; var missing: [UUID] = []
        for id in profileIDs {
            if next.retiredLegacyAccounts.contains(id.uuidString) || next.secrets[id.uuidString] != nil {
                if let proposed = source?[id], let current = next.secrets[id.uuidString], proposed != current {
                    throw KeymanError.invalidRequest("原资料与统一凭证库中的 Key 不一致；迁移已停止，未覆盖现有凭证。")
                }
                continue
            }
            let value: String?
            if let source { value = source[id] }
            else { value = try backend.read(service: Self.service, account: id.uuidString).flatMap { String(data: $0, encoding: .utf8) } }
            guard let value, !value.isEmpty else { missing.append(id); continue }
            guard value.utf8.count <= 65_536, !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw KeymanError.invalidRequest("迁移凭证格式异常，尚未写入统一凭证库。")
            }
            next.secrets[id.uuidString] = value
            next.retiredLegacyAccounts.insert(id.uuidString)
            moved.append(id)
        }
        return .init(previous: previous, next: next, migratedIDs: moved, missingIDs: missing)
    }

    public func commitMigration(_ migration: CredentialVaultMigration) throws {
        try writeVault(migration.next)
        do {
            guard try readVault(interactive: true) == migration.next else { throw KeymanError.invalidRequest("统一凭证库回读核对失败。") }
        } catch {
            try rollbackMigration(migration)
            throw error
        }
    }

    public func rollbackMigration(_ migration: CredentialVaultMigration) throws {
        if let previous = migration.previous { try writeVault(previous) }
        else { try backend.delete(service: Self.vaultService, account: Self.vaultAccount) }
    }
}

private struct CredentialVaultPayload: Codable, Equatable, Sendable {
    var version = 1
    var secrets: [String: String] = [:]
    var retiredLegacyAccounts: Set<String> = []
}

/// Deliberately not Codable: contains credentials and must never be a CLI response.
public struct CredentialVaultMigration: Sendable {
    fileprivate var previous: CredentialVaultPayload?
    fileprivate var next: CredentialVaultPayload
    public var migratedIDs: [UUID]
    public var missingIDs: [UUID]
}

public struct CredentialVaultStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable { case stored, cleared, legacyOrMissing }
    public struct Entry: Codable, Sendable {
        public var profileID: UUID
        public var state: State
        public var secretSuffix: String?
    }
    public var exists: Bool
    public var profiles: [Entry]
    public var storage = "macOS Keychain · 单一凭证库"
    public var authorizationHint = "若系统要求授权，输入 Mac 登录密码并选择“始终允许”，让本版本的图形应用与 CLI 使用同一凭证库。选择“允许”仅授权本次；应用签名变化或钥匙串锁定后仍可能再次提示。"
}

public struct SecurityKeychainBackend: KeychainBackend {
    // The legacy login Keychain's interaction flag is process-wide.
    private static let accessLock = NSLock()
    public init() {}

    public func write(service: String, account: String, data: Data) throws {
        try Self.accessLock.withLock { try writeLocked(service: service, account: account, data: data) }
    }

    private func writeLocked(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            if service == KeychainCredentialStore.vaultService {
                insert[kSecAttrLabel as String] = "Keyman API 凭证库"
            }
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw map(insertStatus) }
        } else if status != errSecSuccess {
            throw map(status)
        }
    }

    public func read(service: String, account: String) throws -> Data? {
        try read(service: service, account: account, interactive: true)
    }

    public func readWithoutInteraction(service: String, account: String) throws -> Data? {
        try read(service: service, account: account, interactive: false)
    }

    private func read(service: String, account: String, interactive: Bool) throws -> Data? {
        try Self.accessLock.withLock {
            if interactive { return try readLocked(service: service, account: account, interactive: true) }
            // LAContext applies to modern items; the legacy login Keychain also needs its
            // scoped interaction flag. This only makes authorization fail, never bypasses it.
            var previous = DarwinBoolean(false)
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw KeymanError.keychainDenied }
            defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            return try readLocked(service: service, account: account, interactive: false)
        }
    }

    private func readLocked(service: String, account: String, interactive: Bool) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !interactive {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw map(status) }
        return result as? Data
    }

    public func delete(service: String, account: String) throws {
        try Self.accessLock.withLock { try deleteLocked(service: service, account: account) }
    }

    private func deleteLocked(service: String, account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw map(status)
        }
    }

    private func map(_ status: OSStatus) -> KeymanError {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed
            ? .keychainDenied
            : .providerError(status: Int(status), message: "Keychain 操作失败")
    }
}

public actor InMemoryCredentialStore: CredentialStoring {
    private var values: [UUID: String] = [:]
    public init() {}
    public func save(_ secret: String, for profileID: UUID) async { values[profileID] = secret }
    public func load(for profileID: UUID) async throws -> String {
        guard let value = values[profileID] else { throw KeymanError.keyMissing }
        return value
    }
    public func delete(for profileID: UUID) async { values.removeValue(forKey: profileID) }
    public func maskedSuffix(for profileID: UUID) async throws -> String {
        String(try await load(for: profileID).suffix(4))
    }
}
