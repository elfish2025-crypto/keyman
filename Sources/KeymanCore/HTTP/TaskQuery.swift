import Foundation

public struct TaskProgress: Codable, Equatable, Sendable {
    public var id: String
    public var status: String
    public var terminal: Bool
    public var succeeded: Bool
    public var queryCommand: [String]

    static func validateID(_ id: String) throws {
        guard id.count <= 200, id.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9_-]*$/) != nil else {
            throw KeymanError.invalidRequest("任务编号只能包含字母、数字、下划线和短横线；不能传入网址或路径。")
        }
    }

    static func submitted(body: Data, query: TaskQueryTemplate, profile: String, model: String) throws -> Self {
        let object = try JSONSerialization.jsonObject(with: body)
        guard let id = RequestBodyValidation.value(query.idPath, in: object) as? String else {
            throw KeymanError.providerError(status: 200, message: "创建任务的响应缺少任务编号。请求已经发送，请先查询供应商任务记录，不要自动重新提交。")
        }
        do { try validateID(id) } catch {
            throw KeymanError.providerError(status: 200, message: "返回的任务编号格式无效。请求已经发送，请核对供应商任务记录，不要自动重新提交。")
        }
        let state = RequestBodyValidation.value(query.statusPath, in: object) as? String ?? "submitted"
        let failed = query.failureValues.contains(state)
        return .init(id: id, status: state, terminal: failed, succeeded: false,
            queryCommand: ["keyman", "task", profile, model, id])
    }
}

extension ModelCaller {
    public func query(profileAlias: String, modelAlias: String, taskID: String) async throws -> CallResponse {
        try TaskProgress.validateID(taskID)
        let configuration = try await configurationStore.load()
        guard let profile = configuration.profiles.first(where: { $0.alias == profileAlias }) else { throw KeymanError.profileNotFound(profileAlias) }
        guard let model = profile.models.first(where: { $0.alias == modelAlias }) else { throw KeymanError.modelNotFound(modelAlias) }
        guard profile.isEnabled else { throw KeymanError.profileDisabled(profile.alias) }
        guard model.isEnabled, model.status.isCallable, let template = model.callTemplate,
              let query = template.taskQuery else { throw KeymanError.invalidRequest("此模型尚未配置异步任务查询。") }
        try ManagementValidation.authentication(profile.authentication, required: true)
        try ManagementValidation.template(template, authentication: profile.authentication)
        let url = try KeymanRequestBuilder.url(profile: profile, endpointAlias: template.endpointAlias,
            path: query.path.replacingOccurrences(of: "{id}", with: taskID))
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = 30
        KeymanRequestBuilder.headers(template, to: &request)
        let secret = try await credentialStore.load(for: profile.id)
        let prefix = profile.authentication.prefix
        request.setValue(prefix.isEmpty ? secret : "\(prefix) \(secret)", forHTTPHeaderField: profile.authentication.headerName)
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch { throw KeymanError.networkError("查询未完成，可重新查询同一个任务编号；本次没有创建生成任务。") }
        let safeBody = CredentialRedactor.redact(response.body, secret: secret)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw ProviderResponseValidation.authenticationError(status: response.statusCode, body: safeBody)
        case 429: throw KeymanError.rateLimited
        default: throw KeymanError.providerError(status: response.statusCode, message: String(decoding: safeBody.prefix(4000), as: UTF8.self))
        }
        guard let object = try? JSONSerialization.jsonObject(with: safeBody) as? [String: Any],
              RequestBodyValidation.value(query.queryIDPath ?? query.idPath, in: object) as? String == taskID,
              let status = RequestBodyValidation.value(query.statusPath, in: object) as? String,
              (query.pendingValues + query.successValues + query.failureValues).contains(status) else {
            throw KeymanError.providerError(status: response.statusCode, message: "查询响应的任务编号或状态不符合模板；本次未创建任务。")
        }
        if let returnedModel = object["model"] as? String, let expected = model.modelID, returnedModel != expected {
            throw KeymanError.invalidRequest("该任务的模型版本与当前配置不一致，请选择创建它的模型配置。")
        }
        let succeeded = query.successValues.contains(status)
        if succeeded { try ProviderResponseValidation.validate(safeBody, format: template.responseFormat == .viduVideo ? .viduVideo : .json) }
        let terminal = succeeded || query.failureValues.contains(status)
        let progress = TaskProgress(id: taskID, status: status, terminal: terminal, succeeded: succeeded,
            queryCommand: ["keyman", "task", profileAlias, modelAlias, taskID])
        let verification: OutputVerification?
        if succeeded && WatermarkPolicy.isVisual(model) && configuration.outputPolicy == .noVisibleWatermark {
            verification = await outputVerifier.verify(body: safeBody, model: model, profileAlias: profile.alias)
        } else { verification = nil }
        return CallResponse(statusCode: response.statusCode, headers: response.headers, body: safeBody,
            isAsync: !terminal, verification: verification, task: progress, generationRequestSent: false)
    }
}
