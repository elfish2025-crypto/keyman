import Foundation

public struct CallResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var isAsync: Bool
    public var verification: OutputVerification? = nil
    public var task: TaskProgress? = nil
    public var generationRequestSent: Bool = true
}

public protocol ModelCalling: Sendable {
    func call(profileAlias: String, modelAlias: String, body: Data, policyOverride: OutputPolicy?) async throws -> CallResponse
    func query(profileAlias: String, modelAlias: String, taskID: String) async throws -> CallResponse
}

public extension ModelCalling {
    func query(profileAlias: String, modelAlias: String, taskID: String) async throws -> CallResponse {
        throw KeymanError.invalidRequest("当前调用器不支持任务查询。")
    }
    func call(profileAlias: String, modelAlias: String, body: Data) async throws -> CallResponse {
        try await call(profileAlias: profileAlias, modelAlias: modelAlias, body: body, policyOverride: nil)
    }
}

public enum CredentialRedactor {
    public static func redact(_ data: Data, secret: String) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(text.replacingOccurrences(of: secret, with: "[REDACTED]").utf8)
    }
}

public struct ModelCaller: ModelCalling {
    let configurationStore: any ConfigurationStoring
    let credentialStore: any CredentialStoring
    private let requestBuilder: any RequestBuilding
    let transport: any HTTPTransporting
    let outputVerifier: any OutputVerifying
    private let audioStore: AudioArtifactStore

    public init(
        configurationStore: any ConfigurationStoring,
        credentialStore: any CredentialStoring,
        requestBuilder: any RequestBuilding = KeymanRequestBuilder(),
        transport: any HTTPTransporting = URLSessionHTTPTransport(),
        outputVerifier: any OutputVerifying = OutputVerifier(),
        audioStore: AudioArtifactStore = AudioArtifactStore()
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.requestBuilder = requestBuilder
        self.transport = transport
        self.outputVerifier = outputVerifier
        self.audioStore = audioStore
    }

    public func call(
        profileAlias: String,
        modelAlias: String,
        body: Data,
        policyOverride: OutputPolicy? = nil
    ) async throws -> CallResponse {
        let configuration = try await configurationStore.load()
        guard let profile = configuration.profiles.first(where: { $0.alias == profileAlias }) else {
            throw KeymanError.profileNotFound(profileAlias)
        }
        guard let model = profile.models.first(where: { $0.alias == modelAlias }) else {
            throw KeymanError.modelNotFound(modelAlias)
        }
        guard profile.isEnabled else { throw KeymanError.profileDisabled(profile.alias) }
        guard model.isEnabled && model.status.isCallable else { throw KeymanError.modelNotEnabled(model.alias) }
        let policy = policyOverride ?? configuration.outputPolicy
        // Validate the complete request before reading a credential or contacting a provider.
        var request = try requestBuilder.build(
            profile: profile,
            model: model,
            secret: "",
            body: body,
            policy: policy
        )
        let secret = try await credentialStore.load(for: profile.id)
        let prefix = profile.authentication.prefix
        request.setValue(prefix.isEmpty ? secret : "\(prefix) \(secret)",
                         forHTTPHeaderField: profile.authentication.headerName)
        do {
            let response = try await transport.send(request)
            var safeBody = CredentialRedactor.redact(response.body, secret: secret)
            switch response.statusCode {
            case 200..<300:
                if model.callTemplate?.responseFormat == .volcengineTTSSSE {
                    let audio = try VolcengineSSEAudio.decode(safeBody)
                    let requestObject = try JSONSerialization.jsonObject(with: request.httpBody ?? body)
                    let format = RequestBodyValidation.value("req_params.audio_params.format", in: requestObject) as? String ?? "mp3"
                    let sampleRate = RequestBodyValidation.value("req_params.audio_params.sample_rate", in: requestObject) as? Int ?? 24000
                    safeBody = try audioStore.save(audio, format: format, sampleRate: sampleRate)
                } else {
                    try ProviderResponseValidation.validate(safeBody, format: model.callTemplate?.responseFormat ?? .json)
                }
                let task = try model.callTemplate?.taskQuery.map { query in
                    try TaskProgress.submitted(body: safeBody, query: query, profile: profile.alias, model: model.alias)
                }
                let verification: OutputVerification?
                if WatermarkPolicy.isVisual(model) && policy == .noVisibleWatermark {
                    verification = await outputVerifier.verify(body: safeBody, model: model, profileAlias: profile.alias)
                } else { verification = nil }
                return CallResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: safeBody,
                    isAsync: model.callTemplate?.isAsync == true,
                    verification: verification,
                    task: task
                )
            case 401, 403: throw ProviderResponseValidation.authenticationError(status: response.statusCode, body: safeBody)
            case 429: throw KeymanError.rateLimited
            default:
                throw KeymanError.providerError(
                    status: response.statusCode,
                    message: String(data: safeBody, encoding: .utf8) ?? "供应商请求失败"
                )
            }
        } catch let error as KeymanError {
            throw error
        } catch {
            throw KeymanError.networkError(NetworkFailureDiagnostic.message(error, elapsed: 0))
        }
    }
}
