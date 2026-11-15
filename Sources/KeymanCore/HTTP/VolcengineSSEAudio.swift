import Foundation

public struct DecodedAudio: Sendable {
    public var bytes: Data
    public var usage: [String: JSONValue]?
}

/// The V3 SSE endpoint ends with code 20000000. EOF alone is never success.
public enum VolcengineSSEAudio {
    public static func decode(_ body: Data) throws -> DecodedAudio {
        guard body.count <= 96 * 1024 * 1024, let text = String(data: body, encoding: .utf8) else {
            throw failure("响应过大或不是 UTF-8 SSE。")
        }
        var audio = Data(), lines: [String] = [], event = "", finished = false
        var usage: [String: JSONValue]?
        func dispatch() throws {
            defer { lines.removeAll(keepingCapacity: true); event = "" }
            guard !lines.isEmpty else { return }
            guard !finished else { throw failure("结束标记后仍返回内容。") }
            let data = Data(lines.joined(separator: "\n").utf8)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = object["code"] as? Int else { throw failure("事件不是有效的语音响应。") }
            guard !["151", "153"].contains(event), code == 0 || code == 20000000 else {
                let message = String((object["message"] as? String ?? "语音服务失败").prefix(2000))
                throw failure("供应商代码 \(code)：\(message)")
            }
            if let value = object["data"], !(value is NSNull) {
                guard let base64 = value as? String, let bytes = Data(base64Encoded: base64),
                      !bytes.isEmpty, audio.count + bytes.count <= 64 * 1024 * 1024 else {
                    throw failure("音频分段无效或音频超过 64 MiB。")
                }
                audio.append(bytes)
            }
            if code == 20000000 {
                finished = true
                if let value = object["usage"] as? [String: Any] {
                    usage = try JSONValue.object(from: JSONSerialization.data(withJSONObject: value))
                }
            }
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { try dispatch() }
            else if line.hasPrefix("data:") { lines.append(String(line.dropFirst(5)).droppingOneSpace) }
            else if line.hasPrefix("event:") { event = String(line.dropFirst(6)).droppingOneSpace }
        }
        try dispatch()
        guard finished, !audio.isEmpty else { throw failure("未收到完整结束标记或没有音频。") }
        return .init(bytes: audio, usage: usage)
    }

    private static func failure(_ detail: String) -> KeymanError {
        .providerError(status: 200, message: "语音未完成：\(detail) 请求已经发送，请勿自动重复合成。")
    }
}

private extension String {
    var droppingOneSpace: String { hasPrefix(" ") ? String(dropFirst()) : self }
}

public struct AudioArtifactStore: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Keyman/Calls")) { self.root = root }

    public func save(_ audio: DecodedAudio, format: String, sampleRate: Int) throws -> Data {
        let extensions = ["mp3": "mp3", "ogg_opus": "ogg", "pcm": "pcm"]
        guard let ext = extensions[format] else { throw KeymanError.invalidRequest("无法保存该音频格式。") }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("audio." + ext)
            try audio.bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            struct Receipt: Encodable {
                var ok = true
                var streamComplete = true
                var audioFile: String
                var format: String
                var sampleRate: Int
                var byteCount: Int
                var usage: [String: JSONValue]?
                var contentQualityVerified = false
                var automaticRetryAllowed = false
            }
            let receipt = try JSONEncoder().encode(Receipt(audioFile: file.path, format: format,
                sampleRate: sampleRate, byteCount: audio.bytes.count, usage: audio.usage))
            let receiptFile = directory.appendingPathComponent("response.json")
            try receipt.write(to: receiptFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptFile.path)
            return receipt
        } catch {
            throw KeymanError.invalidRequest("语音已经生成，但本机保存未完成：\(directory.path)。请检查现有文件，不要自动重复合成。")
        }
    }
}
