import Foundation
import CoreFoundation

/// The Q3 video contracts checked against Vidu's China API docs on 2026-09-17.
/// File dimensions and provider permissions still require inspecting inputs / a real request.
enum ViduVideoValidation {
    static func validate(_ body: [String: Any], path: String) throws {
        let reference = path == "/ent/v2/reference2video"
        let image = path == "/ent/v2/img2video"
        let frames = path == "/ent/v2/start-end2video"
        let text = path == "/ent/v2/text2video"
        let models = reference ? ["viduq3", "viduq3-turbo", "viduq3-mix"]
            : image ? ["viduq3-pro", "viduq3-turbo", "viduq3-pro-fast"] : ["viduq3-pro", "viduq3-turbo"]
        guard reference || image || frames || text, let model = body["model"] as? String, models.contains(model) else {
            throw invalid("当前适配的 Q3 型号与调用路径不匹配；图/文/首尾帧用 viduq3-pro 或 viduq3-turbo，参考生用 viduq3 或 viduq3-turbo。")
        }
        let common: Set<String> = ["model", "prompt", "duration", "seed", "resolution", "audio", "bgm", "off_peak",
            "watermark", "wm_position", "wm_url", "meta_data", "payload", "callback_url", "movement_amplitude"]
        let extra: Set<String> = reference ? ["images", "subjects", "auto_subjects", "audio_type", "aspect_ratio"]
            : image ? ["images", "is_rec", "audio_type", "voice_id"]
            : frames ? ["images", "is_rec"] : ["aspect_ratio", "style"]
        guard Set(body.keys).isSubset(of: common.union(extra)) else {
            throw invalid("包含当前 Q3 接口未配置的字段；请根据 guide 核对，避免把其他生成方式的参数混用。")
        }
        for field in ["audio", "bgm", "off_peak", "watermark", "is_rec", "auto_subjects"] {
            if let value = body[field] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw invalid("\(field) 应为 JSON 布尔值。")
                }
            }
        }
        if let value = body["duration"] {
            let seconds = try integer(value, field: "duration")
            guard (reference ? 3...16 : 1...16).contains(seconds) else {
                throw invalid(reference ? "Q3 参考生视频时长应为 3～16 秒。" : "Q3 图/文/首尾帧视频时长应为 1～16 秒。")
            }
        }
        if let value = body["seed"] { guard try integer(value, field: "seed") >= 0 else { throw invalid("seed 不能为负数。") } }
        if let value = body["resolution"] {
            let allowed = ["viduq3-pro-fast", "viduq3-mix"].contains(model) ? ["720p", "1080p"] : ["540p", "720p", "1080p"]
            guard let resolution = value as? String, allowed.contains(resolution) else { throw invalid("分辨率不受该 Q3 型号支持。") }
        }
        if let value = body["aspect_ratio"] {
            let allowed = reference ? ["16:9", "9:16", "1:1"] : ["16:9", "9:16", "3:4", "4:3", "1:1"]
            guard let ratio = value as? String, allowed.contains(ratio) else { throw invalid("画幅比例不受该 Q3 生成方式支持。") }
        }
        if let prompt = body["prompt"] {
            guard let value = prompt as? String, value.count <= (reference && body["subjects"] == nil ? 2000 : 5000) else {
                throw invalid("提示词类型或长度不正确；参考图模式最多 2000 字符，其他已适配模式最多 5000 字符。")
            }
        }
        if reference || text { try RequestBodyValidation.validate(body, fields: ["prompt"]) }
        if image || frames { try images(body["images"], minimum: frames ? 2 : 1, maximum: frames ? 2 : 1) }
        if reference {
            guard (body["images"] != nil) != (body["subjects"] != nil) else {
                throw invalid("参考生视频请在 images 和 subjects 中选择一种输入方式。")
            }
            if let list = body["images"] { try images(list, minimum: 1, maximum: 7) }
            else {
                guard model != "viduq3-mix", let subjects = body["subjects"] as? [[String: Any]], (1...7).contains(subjects.count) else {
                    throw invalid("该型号不支持此主体列表；Q3/ Q3 Turbo 支持 1～7 个图片或已有主体，Q3 Mix 只支持图片数组。")
                }
                var names = Set<String>()
                for subject in subjects {
                    guard Set(subject.keys).isSubset(of: ["name", "images", "server_id", "voice_id"]),
                          let name = subject["name"] as? String, names.insert(name).inserted else {
                        throw invalid("主体需要不重复的 name；当前 Q3 配置不接收视频主体或未知主体字段。")
                    }
                    try RequestBodyValidation.validate(subject, fields: ["name"])
                    guard (subject["images"] != nil) != (subject["server_id"] != nil) else {
                        throw invalid("每个主体提供 images 或账号已有 server_id 中的一种。")
                    }
                    if let list = subject["images"] { try images(list, minimum: 1, maximum: 3) }
                    else {
                        guard subject["server_id"] is String else { throw invalid("server_id 必须是实际已有主体的字符串编号。") }
                        try RequestBodyValidation.validate(subject, fields: ["server_id"])
                    }
                }
            }
        }
        if let callback = body["callback_url"] { try remoteURL(callback) }
    }

    private static func integer(_ value: Any, field: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = value as? Int else { throw invalid("\(field) 应为 JSON 整数。") }
        return result
    }
    private static func images(_ value: Any?, minimum: Int, maximum: Int) throws {
        guard let list = value as? [String], (minimum...maximum).contains(list.count) else {
            throw invalid("此输入需要 \(minimum == maximum ? String(minimum) : "\(minimum)～\(maximum)") 张图片组成的字符串数组。")
        }
        for value in list {
            if value.hasPrefix("data:image/") {
                let parts = value.split(separator: ",", maxSplits: 1).map(String.init)
                guard parts.count == 2, ["data:image/png;base64", "data:image/jpeg;base64", "data:image/jpg;base64", "data:image/webp;base64"].contains(parts[0]),
                      let bytes = Data(base64Encoded: parts[1]), !bytes.isEmpty else { throw invalid("图片 Base64 必须含有效内容和图片类型前缀。") }
            } else { try remoteURL(value) }
        }
    }
    private static func remoteURL(_ value: Any) throws {
        guard let value = value as? String, !value.contains(where: \.isWhitespace),
              let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), host.contains("."), url.user == nil, url.password == nil,
              !["example.com", "example.org", "example.net", "127.0.0.1"].contains(host),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !value.uppercased().contains("REPLACE_"), !value.uppercased().contains("YOUR_") else {
            throw invalid("图片或回调须使用供应商可访问的真实 URL，不能是本机路径或示例占位地址。")
        }
    }
    private static func invalid(_ message: String) -> KeymanError {
        .invalidRequest("Vidu：\(message) 本次尚未读取 Key 或发送请求。")
    }
}
