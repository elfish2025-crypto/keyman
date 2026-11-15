import Foundation

public protocol RequestBuilding: Sendable {
    func build(
        profile: ProviderProfile,
        model: ModelRecord,
        secret: String,
        body: Data,
        policy: OutputPolicy
    ) throws -> URLRequest
}

public struct KeymanRequestBuilder: RequestBuilding {
    public init() {}

    public func build(
        profile: ProviderProfile,
        model: ModelRecord,
        secret: String,
        body: Data,
        policy: OutputPolicy = .noVisibleWatermark
    ) throws -> URLRequest {
        guard profile.isEnabled else { throw KeymanError.profileDisabled(profile.alias) }
        guard model.isEnabled && model.status.isCallable else {
            throw KeymanError.modelNotEnabled(model.alias)
        }
        try ManagementValidation.authentication(profile.authentication, required: true)
        guard model.hasRequiredModelID, let template = model.callTemplate else {
            throw KeymanError.modelNotCallable(model.alias)
        }
        try ManagementValidation.template(template, authentication: profile.authentication)
        let url = try Self.url(profile: profile, endpointAlias: template.endpointAlias, path: template.path)

        let prepared = try WatermarkPolicy.prepare(profile: profile, model: model, body: body, policy: policy)
        var object = try JSONSerialization.jsonObject(with: prepared.body)
        guard var dictionary = object as? [String: Any] else {
            throw KeymanError.invalidRequest("请求体必须是 JSON 对象")
        }
        if let field = template.modelIDBodyField, let modelID = model.modelID {
            dictionary[field] = modelID
            object = dictionary
        }
        try RequestBodyValidation.validate(dictionary, fields: template.requiredBodyFields ?? [])
        if template.responseFormat == .viduVideo {
            try ViduVideoValidation.validate(dictionary, path: template.path)
        }
        if template.responseFormat == .volcengineTTSSSE {
            let format = RequestBodyValidation.value("req_params.audio_params.format", in: dictionary) as? String ?? "mp3"
            guard ["mp3", "ogg_opus", "pcm"].contains(format) else {
                throw KeymanError.invalidRequest("豆包语音 SSE 适配器支持 mp3、ogg_opus、pcm；分段 WAV 不支持直接拼接。")
            }
        }

        var request = URLRequest(url: url)
        if WatermarkPolicy.isVisual(model) || template.responseFormat == .volcengineTTSSSE { request.timeoutInterval = 180 }
        if model.modality == .speech && template.responseFormat == .json {
            request.timeoutInterval = 300
        }
        request.httpMethod = template.method.rawValue
        if template.method == .get {
            guard dictionary.isEmpty else { throw KeymanError.invalidRequest("GET 请求不接受 JSON 请求体；查询任务请使用 keyman task。") }
        } else { request.httpBody = try JSONSerialization.data(withJSONObject: object) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.headers(template, to: &request)
        let authValue = profile.authentication.prefix.isEmpty
            ? secret
            : "\(profile.authentication.prefix) \(secret)"
        request.setValue(authValue, forHTTPHeaderField: profile.authentication.headerName)
        return request
    }

    static func headers(_ template: CallTemplate, to request: inout URLRequest) {
        for (name, value) in template.staticHeaders { request.setValue(value, forHTTPHeaderField: name) }
        for name in template.uuidHeaders ?? [] { request.setValue(UUID().uuidString, forHTTPHeaderField: name) }
        if template.responseFormat == .volcengineTTSSSE { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
    }

    static func url(profile: ProviderProfile, endpointAlias: String, path: String) throws -> URL {
        try ManagementValidation.relativePath(path)
        guard let endpoint = profile.endpoints.first(where: { $0.alias == endpointAlias }) else {
            throw KeymanError.endpointNotFound(profile: profile.alias, endpoint: endpointAlias)
        }
        try ManagementValidation.endpoint(endpoint)
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            throw KeymanError.invalidRequest("调用路径必须属于已保存的 Endpoint")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (basePath.isEmpty ? "" : "/" + basePath) + path
        guard let url = components.url, url.host == endpoint.baseURL.host else {
            throw KeymanError.invalidRequest("无法构建已保存 Endpoint 的调用地址")
        }
        return url
    }
}
