import Foundation

/// Curated purpose notes. Incomplete imported names are not treated as exact provider contracts.
public enum BuiltinModelGuides {
    public static func addMissing(to configuration: KeymanConfiguration) -> KeymanConfiguration {
        var result = configuration
        for p in result.profiles.indices {
            let profile = result.profiles[p]
            for m in profile.models.indices where profile.models[m].usageGuide == nil {
                result.profiles[p].models[m].usageGuide = guide(profile: profile, model: profile.models[m])
            }
        }
        return result
    }

    public static func guide(profile: ProviderProfile, model: ModelRecord) -> ModelUsageGuide? {
        let name = model.name.lowercased()
        let incomplete = "目前保存的是导入记录；准确版本、Model ID、认证及调用接口仍需核对，不能仅凭名称直接调用。"
        var guide: ModelUsageGuide?
        switch profile.provider {
        case .volcengineArk:
            if model.modelID == "doubao-seedream-5-0-pro-260628", model.modality == .image,
               let template = model.callTemplate, template.method == .post, template.path == "/images/generations",
               template.modelIDBodyField == "model", template.staticHeaders.isEmpty,
               profile.endpoints.first(where: { $0.alias == template.endpointAlias })?.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://ark.cn-beijing.volces.com/api/v3" {
                guide = .init(summary: "按文字描述生成图片，可用于画面概念、插画和分镜预览。",
                    useCases: ["文生图", "画面概念", "插画", "分镜预览"],
                    inputs: "JSON 请求体：prompt 为画面描述，示例 size 为 2K。Keyman 注入 model 和认证；严格规则自动设置 watermark=false。",
                    outputs: "图片地址及供应商响应；Keyman 另返回成品检查结果。HTTP 成功与图片可以交付是两个状态。",
                    instructions: ["导出 example，修改 prompt，保留已核对的请求字段。", "执行 preflight 检查模型、接口和水印参数。", "获得本任务调用授权后执行 call；查看 ok 和 verification，检查未通过不要自动重新生成。"],
                    limitations: ["本示例覆盖文字生图；参考图编辑、其他尺寸或高级参数需按当前版本文档核对。", "实际调用计费；本地说明不证明当前 Key、余额和远程服务可用。"],
                    documentationURLs: ["https://ark.volcengine.com/region:cn-beijing/docs/82379/2582774?lang=zh"],
                    requestExample: ["prompt": .string("A plain ceramic cup on a wooden table"), "size": .string("2K")])
            } else if name.contains("seedream"), model.modality == .image {
                guide = .init(summary: "根据画面描述生成图片，用于插画、概念设计和分镜预览。", useCases: ["图片生成", "插画", "分镜预览"],
                    inputs: "画面描述以及具体版本支持的图片参数。", outputs: "图片文件或图片地址。", limitations: [incomplete, "需要按当前版本核对水印能力及请求字段。"])
            } else if name.contains("seedance"), model.modality == .video {
                guide = .init(summary: "视频生成模型，用于把创意描述或参考素材转成视频片段。",
                    useCases: ["视频生成", "镜头预览", "动态分镜"], inputs: "文字描述及该具体版本支持的参考素材；字段与限制尚未登记。",
                    outputs: "视频任务或视频文件；是否异步及结果查询方式尚未登记。",
                    limitations: [incomplete, "包含 mini 的导入名称尚未核对到准确版本，不能套用其他 Seedance 版本的参数。", "须先核对无可见水印能力与任务查询流程。"],
                    documentationURLs: ["https://developer.volcengine.com/articles/7628567056649125942"])
            } else if model.modality == .speech && name.contains("语音合成") {
                guide = .init(summary: "把文字转换为语音，用于旁白、对白和配音。", useCases: ["文字转语音", "旁白", "配音"],
                    inputs: "待朗读文字、音色及语音参数；此版本字段尚未登记。", outputs: "音频数据或音频流；具体格式尚待核对。",
                    limitations: [incomplete, "语音服务可能使用独立 App ID、Access Token 或 API Key；不能直接沿用方舟生图认证。", "当前通用 call 处理 JSON HTTP 请求；如需 WebSocket 或流式二进制，应先接入相应适配器。"],
                    documentationURLs: ["https://www.volcengine.com/docs/6561/2228192?lang=zh"])
            } else if model.modality == .voiceDesign && name.contains("音色设计") {
                guide = .init(summary: "创建或定制后续配音使用的音色；音色准备好后再用于语音合成。", useCases: ["音色设计", "角色声音"],
                    inputs: "音色描述或参考材料，取决于实际服务；此导入名称的具体产品尚未确认。", outputs: "可用于后续合成的音色信息；具体返回字段待核对。",
                    limitations: [incomplete, "尚未确认此记录对应自然语言音色设计还是声音复刻，不能混用两种服务。"])
            }
        case .alibabaBailian:
            if model.modality == .voiceDesign && name.contains("qwen") {
                guide = .init(summary: "根据文字描述设计音色，用于后续语音合成和角色配音。", useCases: ["音色设计", "角色配音"],
                    inputs: "描述目标声音的文字及预览文本；准确版本与字段待登记。", outputs: "音色标识及试听结果；再用匹配的语音合成模型生成配音。",
                    limitations: [incomplete, "音色与合成模型的版本必须匹配，不能任意跨模型复用。"],
                    documentationURLs: ["https://help.aliyun.com/zh/model-studio/voice-design-user-guide"])
            } else if model.modality == .speech && (name.contains("qwen") || name.contains("cosyvoice")) {
                guide = .init(summary: "把文字转换为语音，用于旁白、对白与语音播报。", useCases: ["文字转语音", "语音播报", "配音"],
                    inputs: "文本、该版本支持的音色和音频参数；准确版本与字段待登记。", outputs: "音频或实时音频流，取决于具体版本。",
                    limitations: [incomplete, "Qwen 与 CosyVoice 各版本的协议、音色及能力不同，不能共享一份未经核对的调用模板。", "需要 WebSocket 或流式 SDK 的版本尚需适配；Keyman 当前通用 call 只处理 JSON HTTP 请求。"],
                    documentationURLs: ["https://help.aliyun.com/zh/model-studio/realtime-tts-user-guide"])
            }
        case .customREST: break
        }
        if var value = guide {
            value.reviewedAt = Date()
            if value.requestExample != nil { value.contractFingerprint = WatermarkPolicy.fingerprint(profile: profile, model: model) }
            return value
        }
        return nil
    }
}
