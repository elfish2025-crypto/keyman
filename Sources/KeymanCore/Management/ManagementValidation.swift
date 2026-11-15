import Foundation

public enum ManagementValidation {
    public static func endpoint(_ endpoint: EndpointRecord) throws {
        guard !endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let c = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw KeymanError.invalidRequest("接口地址须使用 HTTPS，不含账号密码、查询参数或片段；本机测试可使用 localhost HTTP。")
        }
    }

    public static func authentication(_ auth: AuthenticationConfiguration, required: Bool) throws {
        guard (!required && auth.headerName.isEmpty) || validHeaderName(auth.headerName),
              !auth.prefix.contains(where: { $0.isNewline || $0 == "\0" }),
              auth.environmentVariable.isEmpty || auth.environmentVariable.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_]*$/) != nil else {
            throw KeymanError.invalidRequest("请填写有效的认证 Header 名和环境变量名，认证前缀不能包含换行。")
        }
        let variable = auth.environmentVariable.uppercased()
        guard !["PATH", "HOME", "SHELL", "TMPDIR", "CODEX_HOME", "KEYMAN_OUTPUT_POLICY"].contains(variable),
              !variable.hasPrefix("DYLD_"), !variable.hasPrefix("LD_") else {
            throw KeymanError.invalidRequest("凭证环境变量不能覆盖系统运行配置。")
        }
    }

    public static func template(_ template: CallTemplate, authentication: AuthenticationConfiguration) throws {
        try relativePath(template.path)
        if let field = template.modelIDBodyField, !RequestBodyValidation.validPath(field) || field.contains(".") {
            throw KeymanError.invalidRequest("模型字段须为一个顶层 JSON 字段；不需要 model 参数的服务请留空。")
        }
        let required = template.requiredBodyFields ?? []
        guard required.count <= 64, required.allSatisfy(RequestBodyValidation.validPath) else {
            throw KeymanError.invalidRequest("必填字段须使用点分路径，例如 req_params.speaker，最多 64 项。")
        }
        if let query = template.taskQuery {
            guard template.isAsync, template.method == .post,
                  query.path.components(separatedBy: "{id}").count == 2,
                  RequestBodyValidation.validPath(query.idPath), RequestBodyValidation.validPath(query.statusPath),
                  query.queryIDPath.map(RequestBodyValidation.validPath) ?? true else {
                throw KeymanError.invalidRequest("任务查询只适用于异步 POST；查询路径须包含一次 {id}，并填写任务编号和状态字段。")
            }
            try relativePath(query.path.replacingOccurrences(of: "{id}", with: "task-id"))
            let values = query.pendingValues + query.successValues + query.failureValues
            guard !query.pendingValues.isEmpty, !query.successValues.isEmpty, !query.failureValues.isEmpty,
                  values.count <= 32, Set(values).count == values.count,
                  values.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
                throw KeymanError.invalidRequest("任务等待、成功、失败状态须非空且互不重复。")
            }
        }
        let forbidden = Set(["authorization", "proxy-authorization", "cookie", "x-api-key", "x-api-access-key", "api-key", "x-goog-api-key", "host", "content-length", "connection", "transfer-encoding", authentication.headerName.lowercased()])
        let uuidHeaders = template.uuidHeaders ?? []
        let names = Array(template.staticHeaders.keys) + uuidHeaders
        guard uuidHeaders.count <= 16, Set(names.map { $0.lowercased() }).count == names.count else {
            throw KeymanError.invalidRequest("请求头不能重复；动态 UUID 请求头最多 16 项。")
        }
        for name in names {
            guard validHeaderName(name), !forbidden.contains(name.lowercased()) else {
                throw KeymanError.invalidRequest("附加请求头只能填写非密钥信息；认证信息应由 Keyman 注入，不能写入普通配置。")
            }
        }
        for value in template.staticHeaders.values {
            guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw KeymanError.invalidRequest("附加请求头不能包含换行。")
            }
        }
        if template.responseFormat == .volcengineTTSSSE {
            guard template.method == .post, !template.isAsync, template.modelIDBodyField == nil else {
                throw KeymanError.invalidRequest("豆包语音 SSE 使用同步 POST，不填写顶层 model 字段。")
            }
        }
        if template.responseFormat == .dashscopeTTSAudio {
            guard template.method == .post, !template.isAsync, template.modelIDBodyField == "model",
                  !names.contains(where: { $0.lowercased() == "x-dashscope-sse" }) else {
                throw KeymanError.invalidRequest("百炼完整音频使用非流式 POST，顶层模型字段为 model，不能设置 X-DashScope-SSE。")
            }
        }
        if template.responseFormat == .viduVideo {
            guard template.method == .post, template.isAsync, template.modelIDBodyField == "model",
                  let query = template.taskQuery, query.idPath == "task_id", query.queryIDPath == "id",
                  query.path == "/ent/v2/tasks/{id}/creations", query.statusPath == "state",
                  query.pendingValues == ["created", "queueing", "processing"],
                  query.successValues == ["success"], query.failureValues == ["failed"],
                  template.outputPaths == ["creations.*.url"] else {
                throw KeymanError.invalidRequest("Vidu 视频模板需要区分提交 task_id 与查询 id，使用 state 状态及 creations.*.url 原始成品字段。")
            }
        }
    }

    public static func relativePath(_ path: String) throws {
        var decoded = path
        for _ in 0..<3 { decoded = decoded.removingPercentEncoding ?? decoded }
        guard path.hasPrefix("/"), !decoded.hasPrefix("//"),
              !decoded.split(separator: "/").contains(".."),
              !decoded.contains(where: { $0.isNewline || $0 == "\0" || $0 == "?" || $0 == "#" }),
              URL(string: path)?.scheme == nil else {
            throw KeymanError.invalidRequest("调用路径应为相对接口路径，例如 /images/generations，不能包含主机或上级目录。")
        }
    }

    public static func validHeaderName(_ value: String) -> Bool {
        value.wholeMatch(of: /^[A-Za-z0-9!#$%&'*+.^_`|~-]+$/) != nil
    }
}
