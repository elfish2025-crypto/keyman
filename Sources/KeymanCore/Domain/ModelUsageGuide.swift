import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public static func object(from data: Data) throws -> [String: JSONValue] {
        guard data.count <= 262_144, let value = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw KeymanError.invalidRequest("请求示例须为不超过 256 KiB 的 JSON 对象。")
        }
        return value
    }

    public static func pretty(_ value: [String: JSONValue]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }
}

/// Local instructions describe a model; they never grant permission to call or relax output rules.
public struct ModelUsageGuide: Codable, Equatable, Sendable {
    public var summary: String
    public var useCases: [String]
    public var inputs: String
    public var outputs: String
    public var instructions: [String]
    public var limitations: [String]
    public var documentationURLs: [String]
    public var requestExample: [String: JSONValue]?
    public var contractFingerprint: String?
    public var reviewedAt: Date?

    public init(summary: String = "", useCases: [String] = [], inputs: String = "", outputs: String = "",
                instructions: [String] = [], limitations: [String] = [], documentationURLs: [String] = [],
                requestExample: [String: JSONValue]? = nil, contractFingerprint: String? = nil, reviewedAt: Date? = nil) {
        self.summary = summary; self.useCases = useCases; self.inputs = inputs; self.outputs = outputs
        self.instructions = instructions; self.limitations = limitations; self.documentationURLs = documentationURLs
        self.requestExample = requestExample; self.contractFingerprint = contractFingerprint; self.reviewedAt = reviewedAt
    }

    public static func validate(_ guide: Self) throws {
        let strings = [guide.summary, guide.inputs, guide.outputs] + guide.useCases + guide.instructions + guide.limitations + guide.documentationURLs
        guard strings.allSatisfy({ $0.utf8.count <= 16_384 }), strings.count <= 128 else {
            throw KeymanError.invalidRequest("模型说明过长，请保留用途、参数和使用限制的必要信息。")
        }
        for source in guide.documentationURLs {
            guard let url = URLComponents(string: source), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw KeymanError.invalidRequest("说明文档须为不含账号密码的 HTTPS 地址。") }
        }
        if let example = guide.requestExample {
            _ = try JSONValue.object(from: JSONEncoder().encode(example))
            try validateExample(.object(example), depth: 0)
        }
    }

    private static func validateExample(_ value: JSONValue, depth: Int) throws {
        guard depth <= 24 else { throw KeymanError.invalidRequest("请求示例嵌套过深。") }
        switch value {
        case .object(let dictionary):
            let reserved = Set(["apikey", "authorization", "accesskey", "accesstoken", "secretkey", "clientsecret", "password"])
            for (key, child) in dictionary {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                guard !reserved.contains(normalized) else { throw KeymanError.invalidRequest("请求示例不能包含认证字段；Key 由 Keyman 注入。") }
                try validateExample(child, depth: depth + 1)
            }
        case .array(let values): for child in values { try validateExample(child, depth: depth + 1) }
        default: break
        }
    }
}
