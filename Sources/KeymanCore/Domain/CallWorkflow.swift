import Foundation

public enum CallResponseFormat: String, Codable, CaseIterable, Sendable {
    case json
    case dashscopeTTSAudio = "dashscope-tts-audio"
    case volcengineTTSSSE = "volcengine-tts-sse"
    case volcengineVoiceDesign = "volcengine-voice-design"
    case viduVideo = "vidu-video"
}

/// Queries use the same saved endpoint and authentication as submission, always GET.
public struct TaskQueryTemplate: Codable, Equatable, Sendable {
    public var path: String
    public var idPath: String
    public var queryIDPath: String?
    public var statusPath: String
    public var pendingValues: [String]
    public var successValues: [String]
    public var failureValues: [String]

    public init(path: String, idPath: String = "id", statusPath: String = "status",
                pendingValues: [String] = ["queued", "running"], successValues: [String] = ["succeeded"],
                failureValues: [String] = ["failed", "cancelled"], queryIDPath: String? = nil) {
        self.path = path; self.idPath = idPath; self.statusPath = statusPath
        self.queryIDPath = queryIDPath
        self.pendingValues = pendingValues; self.successValues = successValues; self.failureValues = failureValues
    }
}

public enum RequestBodyValidation {
    public static func value(_ path: String, in object: Any) -> Any? {
        path.split(separator: ".").reduce(Optional(object)) { value, key in
            (value as? [String: Any])?[String(key)]
        }
    }

    public static func validPath(_ path: String) -> Bool {
        path.count <= 256 && path.split(separator: ".").count <= 12
            && path.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*$/) != nil
    }

    public static func validate(_ object: [String: Any], fields: [String]) throws {
        for path in fields {
            guard let value = value(path, in: object), !(value is NSNull) else {
                throw KeymanError.invalidRequest("缺少请求字段 \(path)。请按 guide 填写后再调用；尚未读取 Key。")
            }
            if let string = value as? String {
                let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
                let upper = normalized.uppercased()
                let isSingleToken = !normalized.contains(where: \.isWhitespace)
                let isPlaceholder = isSingleToken && (
                    upper.hasPrefix("REPLACE_") || upper.hasPrefix("YOUR_")
                    || normalized.contains("****")
                    || normalized.wholeMatch(of: /^<[A-Za-z_][A-Za-z0-9_-]*>$/) != nil
                )
                // SSML and prose may legitimately contain tags or mention placeholder syntax.
                guard !normalized.isEmpty, !isPlaceholder else {
                    throw KeymanError.invalidRequest("字段 \(path) 仍为空或为占位值。请提供实际输入或账号拥有的资源编号；尚未读取 Key。")
                }
            }
            if let array = value as? [Any], array.isEmpty {
                throw KeymanError.invalidRequest("字段 \(path) 不能为空数组；尚未读取 Key。")
            }
        }
    }
}
