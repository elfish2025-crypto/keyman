import Foundation
import CryptoKit

public enum OutputPolicy: String, Codable, CaseIterable, Sendable {
    case noVisibleWatermark = "no-visible-watermark"
    case providerDefault = "provider-default"
    public var title: String {
        self == .noVisibleWatermark ? "默认无可见水印" : "允许供应商原有水印行为"
    }
}

public enum WatermarkDisposition: String, Codable, CaseIterable, Sendable {
    case configurable, none, unavoidable, unknown
    public var title: String {
        switch self {
        case .configurable: "可通过参数关闭"
        case .none: "无可见水印，无需开关"
        case .unavoidable: "有固定水印，无法关闭"
        case .unknown: "尚未核对"
        }
    }
}

/// A scalar rather than an arbitrary JSON subtree prevents replacing whole request objects.
public enum JSONScalar: Codable, Equatable, Sendable {
    case bool(Bool), string(String), number(Double)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        }
    }
    public var foundationValue: Any {
        switch self { case .bool(let v): v; case .string(let v): v; case .number(let v): v }
    }
    public var jsonText: String {
        String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "false"
    }
    public static func parse(_ text: String) throws -> JSONScalar {
        try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

public struct WatermarkCapability: Codable, Equatable, Sendable {
    public var disposition: WatermarkDisposition
    public var parameterPath: String?
    public var disabledValue: JSONScalar?
    public var evidence: String
    public var checkedAt: Date
    public var contractFingerprint: String

    public init(disposition: WatermarkDisposition, parameterPath: String? = nil,
                disabledValue: JSONScalar? = nil, evidence: String,
                checkedAt: Date = Date(), contractFingerprint: String) {
        self.disposition = disposition
        self.parameterPath = parameterPath
        self.disabledValue = disabledValue
        self.evidence = evidence
        self.checkedAt = checkedAt
        self.contractFingerprint = contractFingerprint
    }
}

public struct PreparedGeneration: Sendable {
    public var body: Data
    public var policy: OutputPolicy
    public var capability: WatermarkCapability?
    public var requiresInspection: Bool
}

public enum WatermarkPolicy {
    public static func isVisual(_ model: ModelRecord) -> Bool {
        model.modality == .image || model.modality == .video
    }

    public static func fingerprint(profile: ProviderProfile, model: ModelRecord) -> String {
        let template = model.callTemplate
        let endpoint = profile.endpoints.first { $0.alias == template?.endpointAlias }
        let values = [profile.provider.rawValue, model.modelID ?? "", model.modality.rawValue,
                      endpoint?.baseURL.absoluteString ?? "", template?.method.rawValue ?? "",
                      template?.path ?? "", template?.modelIDBodyField ?? "",
                      profile.authentication.headerName.lowercased(), profile.authentication.prefix]
        let headers = template?.staticHeaders.map { "\($0.key):\($0.value)" }.sorted() ?? []
        var workflow: [String] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let format = template?.responseFormat, format != .json { workflow.append("responseFormat:\(format.rawValue)") }
        if let names = template?.uuidHeaders, !names.isEmpty { workflow.append("uuidHeaders:" + names.sorted().joined(separator: ",")) }
        if let fields = template?.requiredBodyFields, !fields.isEmpty { workflow.append("requiredBodyFields:" + fields.sorted().joined(separator: ",")) }
        if let query = template?.taskQuery { workflow.append("taskQuery:" + String(decoding: try! encoder.encode(query), as: UTF8.self)) }
        let data = try! encoder.encode(values + headers + workflow)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func capability(profile: ProviderProfile, model: ModelRecord) -> WatermarkCapability? {
        guard isVisual(model) else { return nil }
        let binding = fingerprint(profile: profile, model: model)
        if let stored = model.watermarkCapability {
            guard stored.contractFingerprint == binding else { return nil }
            return stored
        }
        // Only this exact contract has been verified locally. An alias or a provider name
        // alone is not evidence that another model or endpoint accepts the same field.
        if profile.provider == .volcengineArk,
           profile.authentication.headerName.lowercased() == "authorization",
           profile.authentication.prefix == "Bearer",
           model.modality == .image,
           model.modelID == "doubao-seedream-5-0-pro-260628",
           model.callTemplate?.method == .post,
           model.callTemplate?.path == "/images/generations",
           model.callTemplate?.modelIDBodyField == "model",
           let endpoint = profile.endpoints.first(where: { $0.alias == model.callTemplate?.endpointAlias }),
           endpoint.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == "https://ark.cn-beijing.volces.com/api/v3",
           model.callTemplate?.staticHeaders.isEmpty == true {
            return WatermarkCapability(disposition: .configurable, parameterPath: "watermark",
                disabledValue: .bool(false),
                evidence: "https://ark.volcengine.com/region:cn-beijing/docs/82379/2582774?lang=zh ; 本机 2026-09-11 无可见水印图片实测",
                checkedAt: Date(timeIntervalSince1970: 1789117585), contractFingerprint: binding)
        }
        return nil
    }

    public static func validate(_ capability: WatermarkCapability) throws {
        if capability.disposition != .unknown {
            guard !capability.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !capability.contractFingerprint.isEmpty else {
                throw KeymanError.invalidRequest("请填写水印能力的资料来源或实测依据。")
            }
        }
        if capability.disposition == .configurable {
            guard let path = capability.parameterPath,
                  path.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*$/) != nil,
                  path.split(separator: ".").count <= 8,
                  capability.disabledValue != nil else {
                throw KeymanError.invalidRequest("请填写关闭水印的字段路径和 JSON 标量值，例如 parameters.watermark 与 false。")
            }
            let forbidden: Set<String> = ["model", "prompt", "image", "video", "input", "parameters", "messages"]
            guard !forbidden.contains(path) else {
                throw KeymanError.invalidRequest("水印字段不能覆盖模型、内容或整个参数对象。")
            }
        } else if capability.parameterPath != nil || capability.disabledValue != nil {
            throw KeymanError.invalidRequest("没有水印开关的模型不应配置水印字段。")
        }
    }

    public static func prepare(profile: ProviderProfile, model: ModelRecord, body: Data,
                               policy: OutputPolicy) throws -> PreparedGeneration {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw KeymanError.invalidRequest("请求体必须是 JSON 对象")
        }
        let capability = capability(profile: profile, model: model)
        let visual = isVisual(model)
        if visual && policy == .noVisibleWatermark {
            guard let capability else {
                throw KeymanError.outputPolicyBlocked("模型“\(model.alias)”的水印能力尚未核对，或模型／接口已变化。请先查证并保存能力；没有开关不等于有水印。此次未调用供应商。")
            }
            try validate(capability)
            switch capability.disposition {
            case .configurable:
                try set(capability.disabledValue!.foundationValue,
                        path: capability.parameterPath!.split(separator: ".").map(String.init), in: &object)
            case .none: break // Intentionally do not inject any watermark field.
            case .unavoidable:
                throw KeymanError.outputPolicyBlocked("模型“\(model.alias)”有无法关闭的可见水印，不符合当前输出要求。此次未调用供应商。")
            case .unknown:
                throw KeymanError.outputPolicyBlocked("请先核对模型“\(model.alias)”的水印能力。此次未调用供应商。")
            }
        }
        return PreparedGeneration(body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                                  policy: policy, capability: capability,
                                  requiresInspection: visual && policy == .noVisibleWatermark)
    }

    private static func set(_ value: Any, path: [String], in object: inout [String: Any]) throws {
        let key = path[0]
        if path.count == 1 { object[key] = value; return }
        var child: [String: Any]
        if let existing = object[key] {
            guard let dictionary = existing as? [String: Any] else {
                throw KeymanError.invalidRequest("水印字段路径“\(key)”与现有请求结构冲突，未发送请求。")
            }
            child = dictionary
        } else { child = [:] }
        try set(value, path: Array(path.dropFirst()), in: &child)
        object[key] = child
    }
}
