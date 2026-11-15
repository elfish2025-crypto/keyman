import Foundation
import KeymanCore

enum ProviderPresets {
    static func profile(
        kind: ProviderKind,
        name: String,
        alias: String,
        workspaceID: String?,
        project: String = "default",
        workspaceName: String? = nil
    ) throws -> ProviderProfile {
        let endpoints: [EndpointRecord]
        let auth: AuthenticationConfiguration
        switch kind {
        case .volcengineArk:
            endpoints = [
                .init(
                    id: UUID(),
                    alias: "default",
                    name: "火山方舟北京",
                    baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
                )
            ]
            auth = .init(
                headerName: "Authorization",
                prefix: "Bearer",
                environmentVariable: "ARK_API_KEY"
            )
        case .alibabaBailian:
            guard let workspaceID, !workspaceID.isEmpty else {
                throw KeymanError.invalidRequest("阿里百炼需要 Workspace ID")
            }
            guard workspaceID.wholeMatch(of: /^[a-zA-Z0-9-]+$/) != nil else {
                throw KeymanError.invalidRequest("Workspace ID 只能包含字母、数字和连字符。")
            }
            let origin = "https://\(workspaceID).cn-beijing.maas.aliyuncs.com"
            endpoints = [
                .init(
                    id: UUID(),
                    alias: "openai",
                    name: "OpenAI Compatible",
                    baseURL: URL(string: "\(origin)/compatible-mode/v1")!
                ),
                .init(
                    id: UUID(),
                    alias: "dashscope",
                    name: "DashScope",
                    baseURL: URL(string: "\(origin)/api/v1")!
                )
            ]
            auth = .init(
                headerName: "Authorization",
                prefix: "Bearer",
                environmentVariable: "DASHSCOPE_API_KEY"
            )
        case .customREST:
            throw KeymanError.invalidRequest("自定义 REST 配置必须由高级设置提供 Endpoint")
        }
        return ProviderProfile(
            id: UUID(),
            alias: alias,
            name: name,
            provider: kind,
            project: kind == .volcengineArk ? project : nil,
            region: "cn-beijing",
            workspaceName: kind == .alibabaBailian ? workspaceName : nil,
            workspaceID: workspaceID,
            endpoints: endpoints,
            authentication: auth,
            notes: nil,
            sourceFiles: [],
            models: [],
            lastTestedAt: nil,
            lastTestSucceeded: nil
        )
    }

    static func customProfile(
        name: String,
        alias: String,
        baseURL: String,
        headerName: String,
        prefix: String,
        environmentVariable: String
    ) throws -> ProviderProfile {
        guard let url = URL(string: baseURL), url.host != nil else {
            throw KeymanError.invalidRequest("自定义 REST Base URL 无效")
        }
        let endpoints: [EndpointRecord] = [
            .init(id: UUID(), alias: "default", name: "Default", baseURL: url)
        ]
        let auth = AuthenticationConfiguration(
            headerName: headerName,
            prefix: prefix,
            environmentVariable: environmentVariable
        )
        return ProviderProfile(
            id: UUID(),
            alias: alias,
            name: name,
            provider: .customREST,
            project: nil,
            region: nil,
            workspaceName: nil,
            workspaceID: nil,
            endpoints: endpoints,
            authentication: auth,
            notes: nil,
            sourceFiles: [],
            models: [],
            lastTestedAt: nil,
            lastTestSucceeded: nil
        )
    }
}
