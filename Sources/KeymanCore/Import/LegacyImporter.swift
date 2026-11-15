import Foundation

public struct ImportedProfilePreview: Sendable {
    public var profile: ProviderProfile
    public var secret: String?
    public var secretSuffix: String?
}

public struct ImportPreview: Sendable {
    public var profiles: [ImportedProfilePreview]
}

public protocol LegacyImporting: Sendable {
    func preview(rootURL: URL) throws -> ImportPreview
}

public struct LegacyImporter: LegacyImporting {
    public init() {}

    public func preview(rootURL: URL) throws -> ImportPreview {
        let arkDirectory = rootURL.appendingPathComponent("火山方舟")
        let bailianDirectory = rootURL.appendingPathComponent("阿里百炼")
        var profiles = [
            try parseArk(directory: arkDirectory),
            try parseBailian(directory: bailianDirectory)
        ]
        profiles += try parseAdditionalArkAccounts(directory: arkDirectory)
        profiles += try parseSpeechCredentials(directory: arkDirectory)
        if let vidu = try parseVidu(directory: bailianDirectory) { profiles.append(vidu) }
        if let minimax = try parseMiniMax(rootURL: rootURL) { profiles.append(minimax) }
        for index in profiles.indices {
            profiles[index].profile = BuiltinModelGuides.addMissing(to: .init(profiles: [profiles[index].profile])).profiles[0]
        }
        return ImportPreview(profiles: profiles)
    }

    private func parseArk(directory: URL) throws -> ImportedProfilePreview {
        let accountFile = directory.appendingPathComponent("火山方舟 API key 管理+ Ark CLI.md")
        let guideFile = directory.appendingPathComponent("火山方舟-seeddream API 调用指南.md")
        let account = try String(contentsOf: accountFile, encoding: .utf8)
        let guide = try String(contentsOf: guideFile, encoding: .utf8)
        let name = value(after: "名称：", in: account) ?? "Example-Ark"
        let secret = value(after: "API Key：", in: account)
            ?? value(after: "API Key:", in: account)
        let project = value(after: "所属项目：", in: account) ?? "default"
        let opened = linesAfter(marker: "开通模型：", in: account)
        let exactSeedreamID = firstMatch(
            pattern: #"doubao-seedream-5-0-pro-[0-9]+"#,
            in: guide
        )
        let models = opened.map {
            arkModel(displayName: $0, seedreamID: exactSeedreamID, source: guideFile.path)
        }
        let profile = ProviderProfile(
            id: UUID(),
            alias: slug(name),
            name: name,
            provider: .volcengineArk,
            project: project,
            region: "cn-beijing",
            workspaceName: nil,
            workspaceID: nil,
            endpoints: [
                EndpointRecord(
                    id: UUID(),
                    alias: "default",
                    name: "火山方舟北京",
                    baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
                )
            ],
            authentication: .init(
                headerName: "Authorization",
                prefix: "Bearer",
                environmentVariable: "ARK_API_KEY"
            ),
            notes: nil,
            sourceFiles: [accountFile.path, guideFile.path],
            models: models,
            lastTestedAt: nil,
            lastTestSucceeded: nil
        )
        return ImportedProfilePreview(
            profile: profile,
            secret: secret,
            secretSuffix: secret.map { String($0.suffix(4)) }
        )
    }

    private func parseBailian(directory: URL) throws -> ImportedProfilePreview {
        let csvURL = try findSingleCSV(in: directory)
        let rows = try parseTwoColumnCSV(csvURL)
        let workspaceID = rows["workspaceId"]
        let apiHost = try requiredURL(rows["apiHost"], field: "apiHost", prependSchemeIfMissing: true)
        let openAI = try requiredURL(rows["openAiCompatible"], field: "openAiCompatible")
        let dashScope = try requiredURL(rows["dashScope"], field: "dashScope")
        let profile = ProviderProfile(
            id: UUID(),
            alias: slug(rows["description"] ?? "example-workspace", fallback: workspaceID),
            name: rows["description"] ?? "example-workspace",
            provider: .alibabaBailian,
            project: nil,
            region: "cn-beijing",
            workspaceName: rows["workspaceName"],
            workspaceID: workspaceID,
            endpoints: [
                .init(id: UUID(), alias: "api-host", name: "API Host", baseURL: apiHost),
                .init(id: UUID(), alias: "openai", name: "OpenAI Compatible", baseURL: openAI),
                .init(id: UUID(), alias: "dashscope", name: "DashScope", baseURL: dashScope)
            ],
            authentication: .init(
                headerName: "Authorization",
                prefix: "Bearer",
                environmentVariable: "DASHSCOPE_API_KEY"
            ),
            notes: nil,
            sourceFiles: [csvURL.path] + (try markdownFiles(in: directory))
                .filter { $0.lastPathComponent != "vidu-api kye.md" }.map(\.path),
            models: bailianCandidateModels(sourceDirectory: directory.path),
            lastTestedAt: nil,
            lastTestSucceeded: nil
        )
        let secret = rows["apiKey"]
        return ImportedProfilePreview(
            profile: profile,
            secret: secret,
            secretSuffix: secret.map { String($0.suffix(4)) }
        )
    }
}

private extension LegacyImporter {
    // These are account headers, not arbitrary example tokens in documentation.
    // In particular, the speech API key is unrelated to Ark's Bearer key.
    func accountValue(_ label: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).prefix(24)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (index, line) in lines.enumerated() {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }),
                  line[..<separator].trimmingCharacters(in: .whitespaces) == label else { continue }
            let inline = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !inline.isEmpty { return inline }
            let next = index + 1
            if next < lines.count, !lines[next].isEmpty,
               !lines[next].contains(":"), !lines[next].contains("：") {
                return lines[next]
            }
        }
        return nil
    }

    func parseAdditionalArkAccounts(directory: URL) throws -> [ImportedProfilePreview] {
        let files = ["火山方舟-seeddream API 调用指南.md", "火山方舟-seedance API 调用指南.md"]
        let primary = try parseArk(directory: directory)
        var result: [ImportedProfilePreview] = []
        for filename in files {
            let url = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let secret = accountValue("API Key", in: text) else { continue }
            if secret == primary.secret { continue }
            if let index = result.firstIndex(where: { $0.secret == secret }) {
                result[index].profile.sourceFiles.append(url.path)
                continue
            }
            let name = accountValue("名称", in: text) ?? "补充火山账号"
            // A guide does not prove model enablement for a different account.
            let profile = ProviderProfile(id: UUID(), alias: "ark-" + slug(name), name: name,
                provider: .volcengineArk, project: nil, region: "cn-beijing",
                workspaceName: nil, workspaceID: nil, endpoints: primary.profile.endpoints,
                authentication: primary.profile.authentication,
                notes: "从调用指南的账号信息导入。模型开通情况尚未验证；使用前补充该账号的模型配置。",
                sourceFiles: [url.path], models: [], lastTestedAt: nil, lastTestSucceeded: nil)
            result.append(.init(profile: profile, secret: secret, secretSuffix: String(secret.suffix(4))))
        }
        return result
    }

    func parseSpeechCredentials(directory: URL) throws -> [ImportedProfilePreview] {
        let url = directory.appendingPathComponent("火山方舟-seedaudio1.0 API Kye 调用指南.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let appID = accountValue("APP ID", in: text)
        let fields = [
            ("API Key", "volc-speech-api", "火山语音 · API Key", "VOLC_SPEECH_API_KEY", "X-Api-Key"),
            ("Access Token", "volc-speech-access-token", "火山语音 · Access Token", "VOLC_SPEECH_ACCESS_TOKEN", "X-Api-Access-Key"),
            ("Secret Key", "volc-speech-secret-key", "火山语音 · Secret Key", "VOLC_SPEECH_SECRET_KEY", "")
        ]
        return fields.compactMap { label, alias, name, variable, header in
            guard let secret = accountValue(label, in: text) else { return nil }
            let profile = ProviderProfile(id: UUID(), alias: alias, name: name,
                provider: .customREST, project: "火山语音", region: nil,
                workspaceName: nil, workspaceID: appID, endpoints: [],
                authentication: .init(headerName: header, prefix: "", environmentVariable: variable),
                notes: "凭证类型：\(label)。App ID：\(appID ?? "未提供")。同一语音应用的三种凭证分别保存，不能互换。接口与模型待核对，尚未发送测试请求。关联账号：volc-speech-api、volc-speech-access-token、volc-speech-secret-key。",
                sourceFiles: [url.path], models: [], lastTestedAt: nil, lastTestSucceeded: nil)
            return ImportedProfilePreview(profile: profile, secret: secret, secretSuffix: String(secret.suffix(4)))
        }
    }

    func parseVidu(directory: URL) throws -> ImportedProfilePreview? {
        let url = directory.appendingPathComponent("vidu-api kye.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let secret = accountValue("Key", in: text) else {
            throw KeymanError.importInvalid("Vidu 文件存在，但没有找到账号 Key。")
        }
        let name = accountValue("名称", in: text) ?? "Vidu"
        let profile = ProviderProfile(id: UUID(), alias: "vidu-" + slug(name), name: "Vidu · " + name,
            provider: .customREST, project: "Vidu", region: nil,
            workspaceName: nil, workspaceID: accountValue("Key ID", in: text), endpoints: [],
            authentication: .init(headerName: "", prefix: "", environmentVariable: "VIDU_API_KEY"),
            notes: "Vidu 独立凭证，不属于百炼。已保存 Key；调用前须核对官方接口、认证方式、模型与水印能力。来源文档：https://platform.vidu.cn/docs/image-to-video 和 https://platform.vidu.cn/docs/reference-to-video。",
            sourceFiles: [url.path], models: [], lastTestedAt: nil, lastTestSucceeded: nil)
        return .init(profile: profile, secret: secret, secretSuffix: String(secret.suffix(4)))
    }

    func parseMiniMax(rootURL: URL) throws -> ImportedProfilePreview? {
        let url = rootURL.appendingPathComponent("minimax/MiniMax API key.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let secret = accountValue("API Key", in: text) else {
            throw KeymanError.importInvalid("MiniMax 文件存在，但没有找到账号 API Key。")
        }
        let name = accountValue("名称", in: text) ?? "MiniMax"
        let profile = ProviderProfile(id: UUID(), alias: "minimax-" + slug(name), name: "MiniMax · " + name,
            provider: .customREST, project: "MiniMax", region: nil,
            workspaceName: nil, workspaceID: nil, endpoints: [],
            authentication: .init(headerName: "", prefix: "", environmentVariable: "MINIMAX_API_KEY"),
            notes: "已保存 MiniMax API Key。调用前须核对官方接口、认证方式、模型与适用的水印能力。来源文档：https://platform.minimax.cn/docs/api-reference/api-overview。",
            sourceFiles: [url.path], models: [], lastTestedAt: nil, lastTestSucceeded: nil)
        return .init(profile: profile, secret: secret, secretSuffix: String(secret.suffix(4)))
    }

    func value(after marker: String, in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix(marker) })
            .map { String($0.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func linesAfter(marker: String, in text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let index = lines.firstIndex(where: { $0.contains(marker) }) else { return [] }
        return lines.dropFirst(index + 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Doubao-") }
    }

    func firstMatch(pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }

    func slug(_ value: String, fallback: String? = nil) -> String {
        func derive(_ input: String) -> String {
            let parts = input.lowercased().split { !$0.isLetter && !$0.isNumber }
            return parts.joined(separator: "-")
        }
        // An alias must match the ASCII pattern enforced by
        // ConfigurationValidator. A description such as "语音模型" yields a
        // non-ASCII result that is unusable as a programmatic identifier, so
        // treat a non-ASCII (or empty) derived slug as missing and fall back
        // to the workspace id when one is available.
        let primary = derive(value)
        if !primary.isEmpty, primary.allSatisfy(\.isASCII) { return primary }
        if let fallback, !fallback.isEmpty {
            return slug(fallback)
        }
        return "imported-profile"
    }

    func arkModel(
        displayName: String,
        seedreamID: String?,
        source: String
    ) -> ModelRecord {
        let mapping: (String, ModelModality) = switch displayName {
        case "Doubao-Seedream-5.0-pro": ("seedream-5-pro", .image)
        case "Doubao-Seedance-2.0-mini": ("seedance-2-mini", .video)
        case "Doubao-语音合成-2.0": ("speech-2", .speech)
        case "Doubao-音色设计": ("voice-design", .voiceDesign)
        case "Doubao-Seedance-2.0": ("seedance-2", .video)
        default: (slug(displayName), .other)
        }
        let isSeedream = mapping.0 == "seedream-5-pro"
        return ModelRecord(
            id: UUID(),
            alias: mapping.0,
            name: displayName,
            modelID: isSeedream ? seedreamID : nil,
            modality: mapping.1,
            status: .declared,
            callTemplate: isSeedream && seedreamID != nil
                ? CallTemplate(
                    endpointAlias: "default",
                    method: .post,
                    path: "/images/generations",
                    modelIDBodyField: "model",
                    staticHeaders: [:],
                    requestFields: ["prompt", "image", "size", "response_format", "watermark"],
                    isAsync: false
                )
                : nil,
            sourceFile: source,
            lastVerifiedAt: nil
        )
    }

    func findSingleCSV(in directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "csv" }
        guard files.count == 1, let file = files.first else {
            throw KeymanError.importInvalid("阿里百炼目录必须恰好包含一个 CSV")
        }
        return file
    }

    func parseTwoColumnCSV(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let parts = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            let key = String(parts[0]).replacingOccurrences(of: "\u{feff}", with: "")
            result[key] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func requiredURL(
        _ raw: String?,
        field: String,
        prependSchemeIfMissing: Bool = false
    ) throws -> URL {
        guard let raw else {
            throw KeymanError.importInvalid("无效字段：\(field)")
        }
        let resolved = prependSchemeIfMissing && !raw.lowercased().hasPrefix("https://")
            ? "https://" + raw
            : raw
        guard let url = URL(string: resolved), url.host != nil else {
            throw KeymanError.importInvalid("无效字段：\(field)")
        }
        return url
    }

    func markdownFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "md" }
    }

    func bailianCandidateModels(sourceDirectory: String) -> [ModelRecord] {
        let families: [(String, String, ModelModality)] = [
            ("qwen-audio-tts", "Qwen Audio TTS", .speech),
            ("cosyvoice", "CosyVoice", .speech),
            ("qwen3-tts", "Qwen3 TTS", .speech),
            ("qwen3-voice-design", "Qwen3 声音设计", .voiceDesign)
        ]
        return families.map { alias, name, modality in
            ModelRecord(
                id: UUID(),
                alias: alias,
                name: name,
                modelID: nil,
                modality: modality,
                status: .candidate,
                callTemplate: nil,
                sourceFile: sourceDirectory,
                lastVerifiedAt: nil
            )
        }
    }
}

public struct CredentialImportStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case matching, missingProfile, missingCredential, differentCredential, missingSourceKey
        case added, restored
    }
    public var alias: String
    public var name: String
    public var state: State
    public var secretSuffix: String?
    public var storedAlias: String? = nil
    public var profileID: UUID? = nil
}

public struct ImportReport: Codable, Sendable {
    public var ok: Bool
    public var networkRequest = false
    public var credentials: [CredentialImportStatus]
}

public struct LegacyImportCoordinator: Sendable {
    private let configurationStore: any ConfigurationStoring
    private let credentialStore: any CredentialStoring

    public init(
        configurationStore: any ConfigurationStoring,
        credentialStore: any CredentialStoring
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
    }

    public func check(_ preview: ImportPreview) async throws -> ImportReport {
        let current = try await configurationStore.load()
        return try await check(preview, against: current)
    }

    private func check(_ preview: ImportPreview, against current: KeymanConfiguration) async throws -> ImportReport {
        try ConfigurationValidator.validate(.init(profiles: preview.profiles.map(\.profile)))
        var statuses: [CredentialImportStatus] = []
        for item in preview.profiles {
            let state: CredentialImportStatus.State
            let existing = current.profiles.first {
                $0.alias == item.profile.alias || $0.previousAliases.contains(item.profile.alias)
            }
            if item.secret?.isEmpty != false {
                state = .missingSourceKey
            } else if let existing {
                do {
                    state = try await credentialStore.load(for: existing.id) == item.secret
                        ? .matching : .differentCredential
                } catch KeymanError.keyMissing {
                    state = .missingCredential
                }
            } else {
                state = .missingProfile
            }
            statuses.append(.init(alias: item.profile.alias, name: item.profile.name,
                                  state: state, secretSuffix: item.secretSuffix,
                                  storedAlias: existing?.alias, profileID: existing?.id))
        }
        return .init(ok: statuses.allSatisfy { $0.state == .matching }, credentials: statuses)
    }

    @discardableResult
    public func commit(_ preview: ImportPreview) async throws -> ImportReport {
        try await configurationStore.withCredentialMutation { try await commitLocked(preview) }
    }

    private func commitLocked(_ preview: ImportPreview) async throws -> ImportReport {
        let current = try await configurationStore.load()
        var report = try await check(preview, against: current)
        if let conflict = report.credentials.first(where: { $0.state == .differentCredential }) {
            throw KeymanError.importInvalid("账号 \(conflict.alias) 已有不同的 Key，已保留现有凭证。请核对后在该账号中替换 Key；本次尚未写入任何凭证。")
        }
        if let missing = report.credentials.first(where: { $0.state == .missingSourceKey }) {
            throw KeymanError.importInvalid("账号 \(missing.alias) 的来源没有有效 Key，本次尚未写入任何凭证。")
        }
        var merged = current
        for (index, item) in preview.profiles.enumerated() where report.credentials[index].state == .missingProfile {
            guard !current.profiles.contains(where: { $0.id == item.profile.id }) else {
                throw KeymanError.importInvalid("新账号与已有账号的内部标识冲突，本次尚未写入。")
            }
            merged.profiles.append(item.profile)
        }
        for (index, item) in preview.profiles.enumerated()
            where report.credentials[index].state == .missingProfile || report.credentials[index].state == .missingCredential {
            let id = report.credentials[index].profileID ?? item.profile.id
            if let target = merged.profiles.firstIndex(where: { $0.id == id }) {
                merged.profiles[target].credentialRevision += 1
                if credentialStore is KeychainCredentialStore { merged.profiles[target].usesCredentialVault = true }
                merged.profiles[target].lastTestedAt = nil
                merged.profiles[target].lastTestSucceeded = nil
                for modelIndex in merged.profiles[target].models.indices {
                    merged.profiles[target].models[modelIndex].lastVerifiedAt = nil
                    if merged.profiles[target].models[modelIndex].status == .verified {
                        merged.profiles[target].models[modelIndex].status = .declared
                    }
                }
            }
        }
        try ConfigurationValidator.validate(merged)
        if report.ok { return report }
        var writtenIDs: [UUID] = []
        do {
            for (index, item) in preview.profiles.enumerated() {
                let state = report.credentials[index].state
                guard state == .missingProfile || state == .missingCredential, let secret = item.secret else { continue }
                let id = report.credentials[index].profileID ?? item.profile.id
                try await credentialStore.save(secret, for: id)
                writtenIDs.append(id)
                // Verify the stored value before reporting an import as complete.
                guard try await credentialStore.load(for: id) == secret else {
                    throw KeymanError.importInvalid("账号 \(item.profile.alias) 的凭证回读核对失败。")
                }
                report.credentials[index].state = state == .missingProfile ? .added : .restored
            }
            guard try await configurationStore.load() == current else {
                throw KeymanError.importInvalid("导入期间配置被其他窗口修改，请刷新后重新导入。")
            }
            if merged != current { try await configurationStore.save(merged, replacing: current) }
            report.ok = true
            return report
        } catch {
            var rollbackFailed = false
            for id in writtenIDs {
                do { try await credentialStore.delete(for: id) } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw KeymanError.importInvalid("导入未完成，部分凭证也未能恢复。请检查钥匙串访问权限后重新核对。") }
            throw error
        }
    }
}
