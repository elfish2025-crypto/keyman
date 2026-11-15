import Foundation

public struct CredentialSummary: Codable, Equatable, Sendable {
    public var profileAlias: String
    public var configured: Bool
    public var secretSuffix: String?
}

public struct ManagementResult: Codable, Sendable {
    public var ok = true
    public var operation: String
    public var dryRun: Bool
    public var networkRequest = false
    public var profile: ProviderProfile?
    public var model: ModelRecord?
    public var endpoint: EndpointRecord?
    public var credential: CredentialSummary?
}

/// Shared by the GUI and CLI. A metadata edit never reads the Keychain.
public struct KeymanManager: Sendable {
    private let configurations: any ConfigurationStoring
    private let credentials: any CredentialStoring

    public init(configurationStore: any ConfigurationStoring, credentialStore: any CredentialStoring) {
        configurations = configurationStore
        credentials = credentialStore
    }

    public func profile(_ alias: String) async throws -> ProviderProfile {
        let config = try await configurations.load()
        return try find(alias, in: config)
    }

    public func credentialStatus(_ alias: String) async throws -> CredentialSummary {
        let profile = try await profile(alias)
        do {
            let suffix = try await credentials.maskedSuffix(for: profile.id)
            return .init(profileAlias: alias, configured: true, secretSuffix: suffix)
        } catch KeymanError.keyMissing {
            return .init(profileAlias: alias, configured: false, secretSuffix: nil)
        }
    }

    @discardableResult
    public func saveProfile(_ draft: ProviderProfile, original: ProviderProfile? = nil,
                            secret: String? = nil, dryRun: Bool = false) async throws -> ManagementResult {
        guard original == nil || secret == nil else {
            throw KeymanError.invalidRequest("请使用独立的 Key 更换操作更新已有账号的凭证。")
        }
        let current = try await configurations.load()
        var next = current
        var saved = draft
        if let original {
            guard let index = current.profiles.firstIndex(where: { $0.id == original.id }),
                  current.profiles[index] == original, draft.id == original.id else {
                throw KeymanError.configurationChanged
            }
            // Account forms and patches cannot replace the model collection.
            saved.credentialRevision = original.credentialRevision
            saved.usesCredentialVault = original.usesCredentialVault
            saved.previousAliases = original.previousAliases.filter { $0 != saved.alias }
            if saved.alias != original.alias && !saved.previousAliases.contains(original.alias) {
                saved.previousAliases.append(original.alias)
            }
            saved.models = original.models
            for index in saved.models.indices {
                if let oldEndpoint = original.endpoints.first(where: { $0.alias == saved.models[index].callTemplate?.endpointAlias }),
                   let replacement = saved.endpoints.first(where: { $0.id == oldEndpoint.id }) {
                    saved.models[index].callTemplate?.endpointAlias = replacement.alias
                }
            }
            saved.models = resetChangedContracts(old: original, new: saved)
            if saved.endpoints != original.endpoints || saved.authentication != original.authentication || saved.provider != original.provider {
                saved.lastTestedAt = nil; saved.lastTestSucceeded = nil
            }
            next.profiles[index] = saved
        } else {
            guard !current.profiles.contains(where: { $0.id == draft.id }) else { throw KeymanError.configurationChanged }
            saved.lastTestedAt = nil; saved.lastTestSucceeded = nil
            saved.credentialRevision = secret == nil ? 0 : 1
            saved.usesCredentialVault = secret != nil && credentials is KeychainCredentialStore
            guard saved.models.isEmpty else { throw KeymanError.invalidRequest("请先创建账号，再单独添加模型。") }
            next.profiles.append(saved)
        }
        try ConfigurationValidator.validate(next)
        let preparedSecret = try secret.map(Self.prepareSecret)
        let result = ManagementResult(operation: original == nil ? "profile.add" : "profile.update", dryRun: dryRun, profile: saved)
        guard !dryRun else { return result }
        if let preparedSecret {
            try await changeSecret(profile: saved, secret: preparedSecret, current: current, next: next)
        } else {
            try await configurations.save(next, replacing: current)
        }
        return result
    }

    @discardableResult
    public func setProfileEnabled(_ alias: String, enabled: Bool, dryRun: Bool = false) async throws -> ManagementResult {
        let original = try await profile(alias)
        var draft = original; draft.isEnabled = enabled
        var result = try await saveProfile(draft, original: original, dryRun: dryRun)
        result.operation = enabled ? "profile.enable" : "profile.disable"
        return result
    }

    @discardableResult
    public func deleteProfile(_ alias: String, original: ProviderProfile? = nil, dryRun: Bool = false) async throws -> ManagementResult {
        let current = try await configurations.load()
        let profile = try find(alias, in: current)
        if let original, original != profile { throw KeymanError.configurationChanged }
        var next = current; next.profiles.removeAll { $0.id == profile.id }
        let result = ManagementResult(operation: "profile.delete", dryRun: dryRun, profile: profile)
        guard !dryRun else { return result }
        try await changeSecret(profile: profile, secret: nil, current: current, next: next)
        return result
    }

    @discardableResult
    public func setCredential(_ alias: String, secret: String?, expectedProfile: ProviderProfile? = nil,
                              dryRun: Bool = false) async throws -> ManagementResult {
        let prepared = try secret.map(Self.prepareSecret)
        let current = try await configurations.load()
        var profile = try find(alias, in: current)
        if let expectedProfile, expectedProfile != profile { throw KeymanError.configurationChanged }
        profile.lastTestedAt = nil; profile.lastTestSucceeded = nil
        profile.credentialRevision += 1
        if credentials is KeychainCredentialStore { profile.usesCredentialVault = true }
        profile.models = profile.models.map { var m = $0; clearVerification(&m); return m }
        var next = current
        next.profiles[next.profiles.firstIndex { $0.id == profile.id }!] = profile
        let result = ManagementResult(operation: secret == nil ? "key.clear" : "key.set", dryRun: dryRun, profile: profile)
        guard !dryRun else { return result }
        try await changeSecret(profile: profile, secret: prepared, current: current, next: next)
        return result
    }

    @discardableResult
    public func saveModel(_ draft: ModelRecord, profileAlias: String, original: ModelRecord? = nil,
                          expectedProfile: ProviderProfile? = nil, confirmUsageExample: Bool = false, dryRun: Bool = false) async throws -> ManagementResult {
        let current = try await configurations.load()
        let profile = try find(profileAlias, in: current)
        if let expectedProfile, expectedProfile != profile { throw KeymanError.configurationChanged }
        var saved = draft
        var edited = profile
        if saved.usageGuide != original?.usageGuide || confirmUsageExample {
            saved.usageGuide?.reviewedAt = Date()
            // A summary edit must not silently reapprove an old example after an endpoint change.
            if confirmUsageExample || saved.usageGuide?.requestExample != original?.usageGuide?.requestExample || original?.usageGuide == nil {
                let binding = WatermarkPolicy.fingerprint(profile: profile, model: saved)
                saved.usageGuide?.contractFingerprint = binding
            }
        }
        if let original {
            guard let index = profile.models.firstIndex(where: { $0.id == original.id }),
                  profile.models[index] == original, draft.id == original.id else { throw KeymanError.configurationChanged }
            if saved.status == .verified && original.status != .verified {
                throw KeymanError.invalidRequest("不能手动把模型标成已验证。请先保存为已声明，再执行真实调用核对。")
            }
            if WatermarkPolicy.fingerprint(profile: profile, model: original) != WatermarkPolicy.fingerprint(profile: profile, model: saved) {
                clearVerification(&saved)
            }
            edited.models[index] = saved
        } else {
            guard !profile.models.contains(where: { $0.id == saved.id }) else { throw KeymanError.configurationChanged }
            guard saved.status != .verified else { throw KeymanError.invalidRequest("新增模型请使用候选或已声明状态，真实调用后再验证。") }
            saved.lastVerifiedAt = nil
            edited.models.append(saved)
        }
        if let capability = saved.watermarkCapability,
           capability.contractFingerprint != WatermarkPolicy.fingerprint(profile: edited, model: saved) {
            saved.watermarkCapability = unknownCapability(profile: edited, model: saved)
            edited.models[edited.models.firstIndex { $0.id == saved.id }!] = saved
        }
        var next = current
        next.profiles[next.profiles.firstIndex { $0.id == profile.id }!] = edited
        try ConfigurationValidator.validate(next)
        if !dryRun { try await configurations.save(next, replacing: current) }
        return .init(operation: original == nil ? "model.add" : "model.update", dryRun: dryRun, profile: edited, model: saved)
    }

    @discardableResult
    public func deleteModel(_ alias: String, profileAlias: String, expectedProfile: ProviderProfile? = nil,
                            dryRun: Bool = false) async throws -> ManagementResult {
        let current = try await configurations.load()
        var profile = try find(profileAlias, in: current)
        if let expectedProfile, expectedProfile != profile { throw KeymanError.configurationChanged }
        guard let model = profile.models.first(where: { $0.alias == alias }) else { throw KeymanError.modelNotFound(alias) }
        profile.models.removeAll { $0.id == model.id }
        var next = current
        next.profiles[next.profiles.firstIndex { $0.id == profile.id }!] = profile
        if !dryRun { try await configurations.save(next, replacing: current) }
        return .init(operation: "model.delete", dryRun: dryRun, profile: profile, model: model)
    }

    @discardableResult
    public func moveModel(_ alias: String, from sourceAlias: String, to destinationAlias: String,
                          patch: Data, dryRun: Bool = false) async throws -> ManagementResult {
        guard sourceAlias != destinationAlias else { throw KeymanError.invalidRequest("目标账号应与原账号不同。") }
        let current = try await configurations.load()
        var source = try find(sourceAlias, in: current)
        var destination = try find(destinationAlias, in: current)
        guard let original = source.models.first(where: { $0.alias == alias }) else { throw KeymanError.modelNotFound(alias) }
        var moved = try ManagementDocuments.model(patch, existing: original)
        clearVerification(&moved)
        let document = try JSONSerialization.jsonObject(with: patch) as? [String: Any]
        if (document?["usageGuide"] as? [String: Any])?["requestExample"] != nil {
            let binding = WatermarkPolicy.fingerprint(profile: destination, model: moved)
            moved.usageGuide?.contractFingerprint = binding
            moved.usageGuide?.reviewedAt = Date()
        }
        if WatermarkPolicy.isVisual(moved) { moved.watermarkCapability = unknownCapability(profile: destination, model: moved) }
        source.models.removeAll { $0.id == original.id }
        destination.models.append(moved)
        var next = current
        next.profiles[next.profiles.firstIndex { $0.id == source.id }!] = source
        next.profiles[next.profiles.firstIndex { $0.id == destination.id }!] = destination
        try ConfigurationValidator.validate(next)
        if !dryRun { try await configurations.save(next, replacing: current) }
        return .init(operation: "model.move", dryRun: dryRun, profile: destination, model: moved)
    }

    @discardableResult
    public func setModelEnabled(_ alias: String, profileAlias: String, enabled: Bool, dryRun: Bool = false) async throws -> ManagementResult {
        let profile = try await profile(profileAlias)
        guard let original = profile.models.first(where: { $0.alias == alias }) else { throw KeymanError.modelNotFound(alias) }
        var draft = original; draft.isEnabled = enabled
        var result = try await saveModel(draft, profileAlias: profileAlias, original: original, expectedProfile: profile, dryRun: dryRun)
        result.operation = enabled ? "model.enable" : "model.disable"
        return result
    }

    @discardableResult
    public func saveEndpoint(_ draft: EndpointRecord, profileAlias: String, originalAlias: String? = nil,
                             expectedProfile: ProviderProfile? = nil, dryRun: Bool = false) async throws -> ManagementResult {
        let original = try await profile(profileAlias)
        if let expectedProfile, expectedProfile != original { throw KeymanError.configurationChanged }
        var updated = original
        if let alias = originalAlias {
            guard let i = original.endpoints.firstIndex(where: { $0.alias == alias }), draft.id == original.endpoints[i].id else {
                throw KeymanError.endpointNotFound(profile: profileAlias, endpoint: alias)
            }
            updated.endpoints[i] = draft
            for j in updated.models.indices where updated.models[j].callTemplate?.endpointAlias == alias {
                updated.models[j].callTemplate?.endpointAlias = draft.alias
            }
        } else { updated.endpoints.append(draft) }
        // Rename references and invalidate only models whose actual contract changed.
        updated.models = resetChangedContracts(old: original, new: updated)
        let current = try await configurations.load()
        guard try find(profileAlias, in: current) == original else { throw KeymanError.configurationChanged }
        var next = current
        next.profiles[next.profiles.firstIndex { $0.id == original.id }!] = updated
        try ConfigurationValidator.validate(next)
        if !dryRun { try await configurations.save(next, replacing: current) }
        return .init(operation: originalAlias == nil ? "endpoint.add" : "endpoint.update", dryRun: dryRun, profile: updated, endpoint: draft)
    }

    @discardableResult
    public func deleteEndpoint(_ alias: String, profileAlias: String, dryRun: Bool = false) async throws -> ManagementResult {
        let original = try await profile(profileAlias)
        guard let endpoint = original.endpoints.first(where: { $0.alias == alias }) else {
            throw KeymanError.endpointNotFound(profile: profileAlias, endpoint: alias)
        }
        let users = original.models.filter { $0.callTemplate?.endpointAlias == alias }.map(\.alias)
        guard users.isEmpty else { throw KeymanError.invalidRequest("接口仍被模型使用：\(users.joined(separator: "、"))。请先修改这些模型的接口或删除模型。") }
        var draft = original; draft.endpoints.removeAll { $0.id == endpoint.id }
        var result = try await saveProfile(draft, original: original, dryRun: dryRun)
        result.operation = "endpoint.delete"; result.endpoint = endpoint
        return result
    }

    private func find(_ alias: String, in configuration: KeymanConfiguration) throws -> ProviderProfile {
        guard let profile = configuration.profiles.first(where: { $0.alias == alias }) else { throw KeymanError.profileNotFound(alias) }
        return profile
    }

    private func existingSecret(_ id: UUID) async throws -> String? {
        do { return try await credentials.load(for: id) } catch KeymanError.keyMissing { return nil }
    }

    private func changeSecret(profile: ProviderProfile, secret: String?, current: KeymanConfiguration,
                              next: KeymanConfiguration) async throws {
        try await configurations.withCredentialMutation {
            try await changeSecretLocked(profile: profile, secret: secret, current: current, next: next)
        }
    }

    private func changeSecretLocked(profile: ProviderProfile, secret: String?, current: KeymanConfiguration,
                                    next: KeymanConfiguration) async throws {
        guard try await configurations.load() == current else { throw KeymanError.configurationChanged }
        let previous = try await existingSecret(profile.id)
        // Do not proceed after an authorization dialog if another client edited this account.
        guard try await configurations.load() == current else { throw KeymanError.configurationChanged }
        var changed = false
        do {
            if let secret {
                try await credentials.save(secret, for: profile.id)
                changed = true
                guard try await credentials.load(for: profile.id) == secret else { throw KeymanError.invalidRequest("凭证回读核对失败。") }
            } else { try await credentials.delete(for: profile.id); changed = true }
            try await configurations.save(next, replacing: current)
        } catch {
            guard changed else { throw error }
            do {
                if let previous { try await credentials.save(previous, for: profile.id) }
                else { try await credentials.delete(for: profile.id) }
            } catch {
                throw KeymanError.invalidRequest("配置未保存，凭证恢复也未完成。请检查此账号的钥匙串访问权限后重新核对 Key。")
            }
            throw error
        }
    }

    private static func prepareSecret(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 65_536,
              !trimmed.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw KeymanError.invalidRequest("Key 不能为空，不能包含多行或超过 64 KiB。")
        }
        return trimmed
    }

    private func resetChangedContracts(old: ProviderProfile, new: ProviderProfile) -> [ModelRecord] {
        new.models.map { draft in
            guard let original = old.models.first(where: { $0.id == draft.id }),
                  WatermarkPolicy.fingerprint(profile: old, model: original) != WatermarkPolicy.fingerprint(profile: new, model: draft) else { return draft }
            var changed = draft
            clearVerification(&changed)
            if WatermarkPolicy.isVisual(changed) { changed.watermarkCapability = unknownCapability(profile: new, model: changed) }
            return changed
        }
    }

    private func unknownCapability(profile: ProviderProfile, model: ModelRecord) -> WatermarkCapability {
        .init(disposition: .unknown, evidence: "接口或模型配置已改变，需要重新核对。", contractFingerprint: WatermarkPolicy.fingerprint(profile: profile, model: model))
    }

    private func clearVerification(_ model: inout ModelRecord) {
        model.lastVerifiedAt = nil
        if model.status == .verified { model.status = .declared }
    }
}
