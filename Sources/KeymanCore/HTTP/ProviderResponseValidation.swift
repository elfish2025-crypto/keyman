import Foundation

enum ProviderResponseValidation {
    static func authenticationError(status: Int, body: Data) -> KeymanError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail = object?["error"] as? [String: Any] ?? object ?? [:]
        let code = detail["code"].map { String(describing: $0) } ?? "未提供错误码"
        let message = detail["message"] as? String ?? "未提供错误详情"
        return .authenticationRejected(status: status, detail: String("\(code): \(message)".prefix(2000)))
    }
    static func validate(_ body: Data, format: CallResponseFormat) throws {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw KeymanError.providerError(status: 200, message: "预期 JSON 对象，但收到其他响应。请求已经发送，请勿自动重试。")
        }
        let error = object["error"]
        let code = object["code"].flatMap { $0 is NSNull ? nil : String(describing: $0) }
        let embeddedStatus = object["status_code"]
        let invalidStatus = embeddedStatus != nil && !(embeddedStatus is NSNull)
            && (embeddedStatus as? Int).map { !(200..<300).contains($0) } != false
        // DashScope's documented successful SDK envelope uses code="".
        if invalidStatus || (error != nil && !(error is NSNull))
            || (code != nil && !["", "0", "20000000", "Success"].contains(code!)) {
            throw KeymanError.providerError(status: 200,
                message: String(String(decoding: body, as: UTF8.self).prefix(4000)) + " 请求已经发送，请勿自动重试。")
        }
        if format == .dashscopeTTSAudio {
            guard let output = object["output"] as? [String: Any],
                  output["finish_reason"] as? String == "stop",
                  let audio = output["audio"] as? [String: Any],
                  let url = audio["url"] as? String, !url.contains(where: \.isWhitespace),
                  let components = URLComponents(string: url),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  components.host?.isEmpty == false, components.user == nil, components.password == nil else {
                throw KeymanError.providerError(status: 200,
                    message: "百炼语音未返回完整音频（需要 finish_reason=stop 和有效的 output.audio.url）。请求已经发送，请保留响应核对，不要自动重新生成。")
            }
        }
        if format == .volcengineVoiceDesign {
            guard let status = object["status"] as? Int, [2, 4].contains(status),
                  let speaker = object["speaker_id"] as? String, !speaker.isEmpty else {
                throw KeymanError.providerError(status: 200,
                    message: "音色设计尚未返回可用于合成的音色（需要 status=2 或 4 和 speaker_id）。请查询已有音色状态，不要重复训练。")
            }
        }
        if format == .viduVideo {
            let states = ["created", "queueing", "processing", "success", "failed"]
            let errorCode = object["err_code"].flatMap { $0 is NSNull ? nil : String(describing: $0) } ?? ""
            guard let state = object["state"] as? String, states.contains(state),
                  errorCode.isEmpty || errorCode == "0" || state == "failed" else {
                throw KeymanError.providerError(status: 200,
                    message: "Vidu 响应状态或错误码不符合成功协议。请求已经发送，请保留响应核对，不要自动重新生成。")
            }
        }
    }
}
