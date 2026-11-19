import Foundation

/// Partial JSON documents: omitted fields are retained; null clears optional fields.
/// IDs, model collections and validation records are managed by Keyman.
public enum ManagementDocuments {
    public static func profile(_ data: Data, existing: ProviderProfile? = nil) throws -> ProviderProfile {
        var patch = try object(data)
        try keys(patch, allowed: ["alias", "name", "provider", "project", "region", "workspaceName", "workspaceID", "endpoints", "authentication", "notes", "sourceFiles", "isEnabled", "balanceURL"])
        if let auth = patch["authentication"] as? [String: Any] {
            try keys(auth, allowed: ["headerName", "prefix", "environmentVariable"])
        }
        if let endpoints = patch["endpoints"] as? [[String: Any]] {
            patch["endpoints"] = try endpoints.map { value -> [String: Any] in
                try keys(value, allowed: ["alias", "name", "baseURL"])
                var endpoint = value
                endpoint["id"] = existing?.endpoints.first { $0.alias == value["alias"] as? String }?.id.uuidString ?? UUID().uuidString
                return endpoint
            }
        }
        let blank = ProviderProfile(id: UUID(), alias: "", name: "", provider: .customREST,
            project: nil, region: nil, workspaceName: nil, workspaceID: nil, endpoints: [],
            authentication: .init(headerName: "", prefix: "", environmentVariable: ""),
            notes: nil, sourceFiles: [], models: [], lastTestedAt: nil, lastTestSucceeded: nil)
        return try apply(patch, to: existing ?? blank)
    }

    public static func model(_ data: Data, existing: ModelRecord? = nil) throws -> ModelRecord {
        var patch = try object(data)
        try keys(patch, allowed: ["alias", "name", "modelID", "modality", "status", "callTemplate", "sourceFile", "isEnabled", "usageGuide"])
        if let guide = patch["usageGuide"] as? [String: Any] {
            try keys(guide, allowed: ["summary", "useCases", "inputs", "outputs", "instructions", "limitations", "documentationURLs", "requestExample"])
            if existing?.usageGuide == nil {
                patch["usageGuide"] = merge(["summary": "", "useCases": [], "inputs": "", "outputs": "", "instructions": [], "limitations": [], "documentationURLs": []], guide)
            }
        }
        if let template = patch["callTemplate"] as? [String: Any] {
            try keys(template, allowed: ["endpointAlias", "method", "path", "modelIDBodyField", "staticHeaders", "requestFields", "isAsync", "outputPaths", "responseFormat", "uuidHeaders", "requiredBodyFields", "taskQuery"])
            if let query = template["taskQuery"] as? [String: Any] {
                try keys(query, allowed: ["path", "idPath", "queryIDPath", "statusPath", "pendingValues", "successValues", "failureValues"])
            }
            if existing?.callTemplate == nil {
                patch["callTemplate"] = merge(["endpointAlias": "", "method": "POST", "path": "", "staticHeaders": [:], "requestFields": [], "isAsync": false], template)
            }
        }
        let blank = ModelRecord(id: UUID(), alias: "", name: "", modelID: nil, modality: .other,
            status: .candidate, callTemplate: nil, sourceFile: nil, lastVerifiedAt: nil)
        return try apply(patch, to: existing ?? blank)
    }

    public static func endpoint(_ data: Data, existing: EndpointRecord? = nil) throws -> EndpointRecord {
        let patch = try object(data)
        try keys(patch, allowed: ["alias", "name", "baseURL"])
        let blank = EndpointRecord(id: UUID(), alias: "", name: "", baseURL: URL(string: "about:blank")!)
        return try apply(patch, to: existing ?? blank)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeymanError.invalidRequest("管理配置必须是小于 1 MiB 的 JSON 对象。")
        }
        return value
    }

    private static func keys(_ value: [String: Any], allowed: Set<String>) throws {
        guard Set(value.keys).isSubset(of: allowed) else {
            throw KeymanError.invalidRequest("配置包含不支持的字段。请参照管理命令示例；Key、内部 ID 和验证记录不能写入管理配置。")
        }
    }

    private static func merge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var merged = base
        for (key, value) in patch {
            if value is NSNull { merged.removeValue(forKey: key) }
            else if let dictionary = value as? [String: Any] {
                // Header dictionaries are replaced, so a deleted header cannot reappear.
                merged[key] = ["staticHeaders", "requestExample"].contains(key) ? dictionary : merge(base[key] as? [String: Any] ?? [:], dictionary)
            } else { merged[key] = value }
        }
        return merged
    }

    private static func apply<T: Codable>(_ patch: [String: Any], to value: T) throws -> T {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let original = try object(encoder.encode(value))
        do { return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: merge(original, patch))) }
        catch { throw KeymanError.invalidRequest("管理配置缺少必填字段，或字段类型不正确。请参照 JSON 示例。") }
    }
}
