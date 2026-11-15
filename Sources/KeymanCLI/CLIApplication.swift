import Foundation
import KeymanCore

public struct CLIApplication: Sendable {
    let configurationStore: any ConfigurationStoring
    let credentialStore: any CredentialStoring
    let modelCaller: any ModelCalling
    let commandRunner: any CommandRunning
    let legacyImporter: any LegacyImporting

    public init(
        configurationStore: any ConfigurationStoring,
        credentialStore: any CredentialStoring,
        modelCaller: any ModelCalling,
        commandRunner: any CommandRunning,
        legacyImporter: any LegacyImporting
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.modelCaller = modelCaller
        self.commandRunner = commandRunner
        self.legacyImporter = legacyImporter
    }

    public func execute(arguments: [String], stdin: @Sendable () async throws -> Data) async -> CLIResult {
        do {
            switch try CLIParser.parse(arguments) {
            case .management(let command): return try await manage(command, stdin: stdin)
            case .vaultStatus(let unlock):
                guard let vault = credentialStore as? KeychainCredentialStore else { throw KeymanError.invalidRequest("当前环境未使用 macOS 钥匙串。") }
                let config = try await configurationStore.load()
                return CLIOutput.encoded(try await vault.vaultStatus(profileIDs: config.profiles.map(\.id), interactive: unlock))
            case .migrateVault(let path, let dryRun):
                guard let vault = credentialStore as? KeychainCredentialStore else { throw KeymanError.invalidRequest("当前环境未使用 macOS 钥匙串。") }
                let preview = try path.map { try legacyImporter.preview(rootURL: URL(fileURLWithPath: $0)) }
                return CLIOutput.encoded(try await CredentialVaultCoordinator(configurationStore: configurationStore, credentialStore: vault).migrate(source: preview, dryRun: dryRun))
            case .catalog(let query, let json):
                let entries = ModelCatalog.entries(try await configurationStore.load(), query: query)
                if json { return CLIOutput.encoded(entries) }
                let lines = entries.flatMap { entry in
                    ["\(entry.profileAlias) · \(entry.name)"] + (entry.nextAction.map { [$0] } ?? []) + entry.models.map {
                        "  \($0.modelAlias) · \($0.requestReady ? "调用资料齐备" : "待补齐") · \($0.guide?.summary ?? "尚未填写用途")"
                    }
                }
                return .init(exitCode: 0, stdout: Data((lines.joined(separator: "\n") + "\n").utf8), stderr: Data())
            case .guide(let alias, let modelAlias, let json):
                let config = try await configurationStore.load()
                guard let profile = config.profiles.first(where: { $0.alias == alias }) else { throw KeymanError.profileNotFound(alias) }
                guard let model = profile.models.first(where: { $0.alias == modelAlias }) else { throw KeymanError.modelNotFound(modelAlias) }
                let packet = ModelCatalog.packet(profile: profile, model: model, policy: config.outputPolicy)
                if json { return CLIOutput.encoded(packet) }
                return .init(exitCode: 0, stdout: Data((ModelCatalog.description(packet) + "\n").utf8), stderr: Data())
            case .example(let alias, let modelAlias):
                let profile = try await loadProfile(alias)
                guard let model = profile.models.first(where: { $0.alias == modelAlias }) else { throw KeymanError.modelNotFound(modelAlias) }
                return .init(exitCode: 0, stdout: Data((JSONValue.pretty(try ModelCatalog.example(profile: profile, model: model)) + "\n").utf8), stderr: Data())
            case .installGuides(let dryRun):
                let original = try await configurationStore.load()
                let updated = BuiltinModelGuides.addMissing(to: original)
                let added = zip(original.profiles, updated.profiles).reduce(0) { count, pair in
                    count + zip(pair.0.models, pair.1.models).filter { $0.usageGuide == nil && $1.usageGuide != nil }.count
                }
                if !dryRun && added > 0 { try await configurationStore.save(updated, replacing: original) }
                struct Report: Encodable { var addedGuides: Int; var dryRun: Bool; var credentialRead = false; var networkRequest = false }
                return CLIOutput.encoded(Report(addedGuides: added, dryRun: dryRun))
            case .list(let json):
                let config = try await configurationStore.load()
                return CLIOutput.profiles(config.profiles, json: json)
            case .profile(let alias, let json):
                return CLIOutput.profile(try await loadProfile(alias), json: json)
            case .models(let profileAlias, let json):
                let profile = try await loadProfile(profileAlias)
                return CLIOutput.models(profile.models.map { resolvedModel($0, profile: profile) }, json: json)
            case .inspect(let profileAlias, let modelAlias, let json):
                let profile = try await loadProfile(profileAlias)
                guard let model = profile.models.first(where: { $0.alias == modelAlias }) else {
                    throw KeymanError.modelNotFound(modelAlias)
                }
                return CLIOutput.model(resolvedModel(model, profile: profile), json: json)
            case .task(let profile, let model, let id, let seconds):
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(seconds))
                var response = try await modelCaller.query(profileAlias: profile, modelAlias: model, taskID: id)
                while response.task?.terminal == false && seconds > 0 && clock.now < deadline {
                    try await clock.sleep(until: min(deadline, clock.now.advanced(by: .seconds(5))))
                    guard clock.now < deadline else { break }
                    response = try await modelCaller.query(profileAlias: profile, modelAlias: model, taskID: id)
                }
                return try callResult(response)
            case .call(let profile, let model, let source, _):
                let body: Data
                switch source {
                case .file(let path): body = try Data(contentsOf: URL(fileURLWithPath: path))
                case .standardInput: body = try await stdin()
                }
                let response = try await modelCaller.call(
                    profileAlias: profile,
                    modelAlias: model,
                    body: body
                )
                return try callResult(response)
            case .guardedCall(let profileAlias, let modelAlias, let source, let allowWatermark, let preflight):
                let body: Data
                switch source {
                case .file(let path): body = try Data(contentsOf: URL(fileURLWithPath: path))
                case .standardInput: body = try await stdin()
                }
                let config = try await configurationStore.load()
                let policy = allowWatermark ? OutputPolicy.providerDefault : config.outputPolicy
                if preflight {
                    let profile = try await loadProfile(profileAlias)
                    guard let model = profile.models.first(where: { $0.alias == modelAlias }) else {
                        throw KeymanError.modelNotFound(modelAlias)
                    }
                    let request = try KeymanRequestBuilder().build(profile: profile, model: model,
                        secret: "", body: body, policy: policy)
                    let payload: [String: Any] = ["ok": true, "networkRequest": false, "credentialRead": false,
                        "policy": policy.rawValue, "method": request.httpMethod ?? "", "url": request.url?.absoluteString ?? "",
                        "body": try JSONSerialization.jsonObject(with: request.httpBody ?? Data("{}".utf8)),
                        "responseFormat": model.callTemplate?.responseFormat?.rawValue ?? "json",
                        "uuidHeaders": model.callTemplate?.uuidHeaders ?? [],
                        "supportsTaskQuery": model.callTemplate?.taskQuery != nil,
                        "requiresOutputInspection": WatermarkPolicy.isVisual(model) && policy == .noVisibleWatermark]
                    return CLIResult(exitCode: 0, stdout: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), stderr: Data())
                }
                return try callResult(await modelCaller.call(profileAlias: profileAlias, modelAlias: modelAlias,
                    body: body, policyOverride: allowWatermark ? .providerDefault : nil))
            case .run(let profileAlias, let command):
                return try await run(profileAlias: profileAlias, command: command, unchecked: false)
            case .uncheckedRun(let profileAlias, let command):
                return try await run(profileAlias: profileAlias, command: command, unchecked: true)
            case .verify(let paths):
                var results: [MediaInspection] = []
                for path in paths { results.append(await LocalMediaInspector().inspect(URL(fileURLWithPath: path))) }
                struct VerificationResult: Encodable { var ok: Bool; var media: [MediaInspection] }
                let passed = results.allSatisfy { $0.status == .noVisibleMarkDetected }
                return CLIOutput.encoded(VerificationResult(ok: passed, media: results), exitCode: passed ? 0 : 3)
            case .verifyResponse(let profileAlias, let modelAlias, let file):
                let profile = try await loadProfile(profileAlias)
                guard let model = profile.models.first(where: { $0.alias == modelAlias }), WatermarkPolicy.isVisual(model) else {
                    throw KeymanError.modelNotFound(modelAlias)
                }
                let saved = try Data(contentsOf: URL(fileURLWithPath: file))
                let object = try JSONSerialization.jsonObject(with: saved) as? [String: Any]
                let body: Data
                if let provider = object?["providerResponse"] {
                    body = try JSONSerialization.data(withJSONObject: provider)
                } else { body = saved }
                let verification = await OutputVerifier().verify(body: body, model: model, profileAlias: profileAlias)
                struct Result: Encodable { var ok: Bool; var generationRequestSent = false; var verification: OutputVerification }
                return CLIOutput.encoded(Result(ok: verification.deliverable, verification: verification),
                                         exitCode: verification.deliverable ? 0 : 3)
            case .policy(let policy):
                var config = try await configurationStore.load()
                let original = config
                if let policy { config.outputPolicy = policy; try await configurationStore.save(config, replacing: original) }
                struct PolicyResult: Encodable { var ok = true; var policy: OutputPolicy; var title: String }
                return CLIOutput.encoded(PolicyResult(policy: config.outputPolicy, title: config.outputPolicy.title))
            case .configureWatermark(let profileAlias, let modelAlias, let file):
                struct Input: Decodable {
                    var disposition: WatermarkDisposition; var parameterPath: String?
                    var disabledValue: JSONScalar?; var evidence: String?
                }
                let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
                var config = try await configurationStore.load()
                let original = config
                guard let p = config.profiles.firstIndex(where: { $0.alias == profileAlias }) else {
                    throw KeymanError.profileNotFound(profileAlias)
                }
                guard let m = config.profiles[p].models.firstIndex(where: { $0.alias == modelAlias }) else {
                    throw KeymanError.modelNotFound(modelAlias)
                }
                let binding = WatermarkPolicy.fingerprint(profile: config.profiles[p], model: config.profiles[p].models[m])
                let capability = WatermarkCapability(disposition: input.disposition,
                    parameterPath: input.parameterPath, disabledValue: input.disabledValue,
                    evidence: input.evidence ?? "", contractFingerprint: binding)
                try WatermarkPolicy.validate(capability)
                config.profiles[p].models[m].watermarkCapability = capability
                try await configurationStore.save(config, replacing: original)
                return CLIOutput.model(config.profiles[p].models[m], json: true)
            case .help:
                return CLIOutput.help()
            case .importPreview(let path, let json):
                let preview = try legacyImporter.preview(
                    rootURL: URL(fileURLWithPath: path, isDirectory: true)
                )
                return CLIOutput.importPreview(preview, json: json)
            case .importCommit(let path, let json):
                let preview = try legacyImporter.preview(
                    rootURL: URL(fileURLWithPath: path, isDirectory: true)
                )
                let report = try await LegacyImportCoordinator(
                    configurationStore: configurationStore,
                    credentialStore: credentialStore
                ).commit(preview)
                return CLIOutput.importReport(report, json: json)
            case .importCheck(let path, let json):
                let preview = try legacyImporter.preview(rootURL: URL(fileURLWithPath: path, isDirectory: true))
                let report = try await LegacyImportCoordinator(configurationStore: configurationStore,
                    credentialStore: credentialStore).check(preview)
                return CLIOutput.importReport(report, json: json)
            }
        } catch {
            return CLIOutput.error(error)
        }
    }

    func resolvedModel(_ model: ModelRecord, profile: ProviderProfile) -> ModelRecord {
        var copy = model
        copy.watermarkCapability = WatermarkPolicy.capability(profile: profile, model: model)
        return copy
    }

    func callResult(_ response: CallResponse) throws -> CLIResult {
        guard response.verification != nil || response.task != nil else {
            return CLIResult(exitCode: 0, stdout: response.body, stderr: Data())
        }
        let failed = response.task.map { $0.terminal && !$0.succeeded } ?? false
        let pending = response.task.map { !$0.terminal } ?? false
        let deliverable = !failed && !pending && (response.verification?.deliverable ?? true)
        var object: [String: Any] = ["ok": deliverable, "generationRequestSent": response.generationRequestSent,
            "automaticRetryAllowed": false, "httpStatus": response.statusCode,
            "providerResponse": (try? JSONSerialization.jsonObject(with: response.body))
                ?? String(data: response.body, encoding: .utf8) ?? ""]
        if let verification = response.verification { object["verification"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(verification)) }
        if let task = response.task { object["task"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) }
        return CLIResult(exitCode: failed ? 1 : deliverable ? 0 : 3,
            stdout: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), stderr: Data())
    }

    private func run(profileAlias: String, command: [String], unchecked: Bool) async throws -> CLIResult {
        let config = try await configurationStore.load()
        guard config.outputPolicy != .noVisibleWatermark || unchecked else {
            throw KeymanError.outputPolicyBlocked("通用外部命令无法由 Keyman 检查请求参数。请优先使用 keyman call；如用户明确选择兼容豁免，可加 --allow-unchecked-output，并在交付前对成品执行 keyman verify。此次未读取 Key，也未执行外部命令。")
        }
        let profile = try await loadProfile(profileAlias)
        guard profile.isEnabled else { throw KeymanError.profileDisabled(profile.alias) }
        guard !profile.authentication.environmentVariable.isEmpty else {
            throw KeymanError.invalidRequest("此账号尚未配置凭证环境变量名，请先编辑账号认证信息。")
        }
        try ManagementValidation.authentication(profile.authentication, required: false)
        let secret = try await credentialStore.load(for: profile.id)
        let contract = #"{"visibleWatermark":"forbidden","requestEnforced":false,"verifyBeforeDelivery":true,"verificationCommand":"keyman verify <file>"}"#
        let result = try await commandRunner.run(command: command,
            additionalEnvironment: [profile.authentication.environmentVariable: secret,
                "KEYMAN_OUTPUT_POLICY": config.outputPolicy == .noVisibleWatermark ? contract
                    : #"{"visibleWatermark":"provider-default","requestEnforced":false}"#])
        let warning = Data("Keyman：此为外部命令兼容路径，请求参数与成品未经管理器检查；交付前请执行 keyman verify。\n".utf8)
        return CLIResult(exitCode: result.exitCode, stdout: result.stdout, stderr: warning + result.stderr)
    }

    private func loadProfile(_ alias: String) async throws -> ProviderProfile {
        let config = try await configurationStore.load()
        guard let profile = config.profiles.first(where: { $0.alias == alias }) else {
            throw KeymanError.profileNotFound(alias)
        }
        return profile
    }
}
