import Foundation

public struct OutputVerification: Codable, Equatable, Sendable {
    public var status: InspectionStatus
    public var media: [MediaInspection]
    public var responseFile: String?
    public var receiptFile: String?
    public var detail: String
    public var deliverable: Bool { status == .noVisibleMarkDetected && !media.isEmpty }

    public init(status: InspectionStatus, media: [MediaInspection] = [], responseFile: String? = nil,
                receiptFile: String? = nil, detail: String) {
        self.status = status; self.media = media; self.responseFile = responseFile
        self.receiptFile = receiptFile; self.detail = detail
    }
}

public protocol OutputVerifying: Sendable {
    func verify(body: Data, model: ModelRecord, profileAlias: String) async -> OutputVerification
}

public protocol MediaDownloading: Sendable {
    func download(_ url: URL, to directory: URL, name: String) async throws -> URL
}

private final class MediaDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 200 * 1024 * 1024 || totalBytesExpectedToWrite > 200 * 1024 * 1024 {
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.currentRequest?.url, let to = request.url,
              RedirectPolicy.allows(from: from, to: to) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

public struct MediaDownloader: MediaDownloading {
    public init() {}
    public func download(_ url: URL, to directory: URL, name: String) async throws -> URL {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host != "localhost", host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil else {
            throw KeymanError.invalidRequest("结果下载需要公开的 HTTPS 图片／视频地址；不会把 Key 发送到该地址。")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // This separate session has no API authentication headers or shared cookies.
        let (temporary, response) = try await session.download(from: url, delegate: MediaDownloadDelegate())
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw KeymanError.invalidRequest("供应商的结果地址未返回可用文件。")
        }
        let type = response.mimeType ?? ""
        let extensions = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp",
                          "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm"]
        let ext = extensions[type] ?? (["png", "jpg", "jpeg", "webp", "mp4", "mov", "webm"].contains(url.pathExtension.lowercased())
                                     ? url.pathExtension.lowercased() : "bin")
        let destination = directory.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }
}

public struct OutputVerifier: OutputVerifying {
    private let root: URL
    private let inspector: any MediaInspecting
    private let downloader: any MediaDownloading
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Keyman/Calls"),
                inspector: any MediaInspecting = LocalMediaInspector(),
                downloader: any MediaDownloading = MediaDownloader()) {
        self.root = root; self.inspector = inspector; self.downloader = downloader
    }

    public func verify(body: Data, model: ModelRecord, profileAlias: String) async -> OutputVerification {
        var verification = OutputVerification(status: .pending, detail: "生成结果尚未检查，不能直接作为合格成品。")
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let response = directory.appendingPathComponent("response.json")
            try write(body, to: response)
            verification.responseFile = response.path
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw KeymanError.invalidRequest("供应商响应不是 JSON 对象；结果已保留，请勿重复生成。")
            }
            guard !Self.hasError(object) else {
                throw KeymanError.invalidRequest("供应商响应含生成错误或部分失败，不能当作全部生成成功。原响应已保留，请勿自动重试。")
            }
            if let returnedModel = object["model"] as? String, let expected = model.modelID,
               returnedModel != expected {
                throw KeymanError.invalidRequest("供应商返回的模型版本与配置不一致，请重新核对能力。")
            }
            let paths = model.callTemplate?.outputPaths ?? [
                "data.*.url", "data.*.b64_json", "output.results.*.url", "output.video_url",
                "output.choices.*.message.content.*.image", "output.choices.*.message.content.*.video"
            ]
            let values = paths.flatMap { Self.values(in: object, path: $0.split(separator: ".").map(String.init)) }
            if model.callTemplate?.outputPaths == nil, let items = object["data"] as? [[String: Any]], !items.isEmpty {
                guard items.allSatisfy({ ($0["url"] as? String)?.isEmpty == false || ($0["b64_json"] as? String)?.isEmpty == false }) else {
                    throw KeymanError.invalidRequest("部分返回项没有图片数据，不能当作全部生成成功。")
                }
            }
            var seen = Set<String>()
            let sources = values.compactMap { $0 as? String }.filter { seen.insert($0).inserted }
            if sources.isEmpty {
                verification.detail = model.callTemplate?.isAsync == true
                    ? "已提交异步任务，尚未取得成品。请查询已有任务并对下载结果执行 keyman verify；不要重复创建任务。"
                    : "没有识别到可检查的成品地址。请配置返回文件字段，或保存已有结果后执行 keyman verify；不要重复生成。"
            } else {
                guard sources.count <= 16 else { throw KeymanError.invalidRequest("返回文件超过 16 个，需要分批检查。") }
                for (index, value) in sources.enumerated() {
                    do {
                        let file: URL
                        if let url = URL(string: value), url.scheme == "https" {
                            file = try await downloader.download(url, to: directory, name: "output-\(index + 1)")
                        } else {
                            let base64 = value.hasPrefix("data:image/")
                                ? String(value.split(separator: ",", maxSplits: 1).last ?? "") : value
                            guard base64.count <= 70 * 1024 * 1024,
                                  let data = Data(base64Encoded: base64), !data.isEmpty else {
                                throw KeymanError.invalidRequest("不能识别供应商返回的图片数据。")
                            }
                            let ext = data.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? "png"
                                : data.starts(with: [0xff, 0xd8, 0xff]) ? "jpg" : "image"
                            file = directory.appendingPathComponent("output-\(index + 1).\(ext)")
                            try write(data, to: file)
                        }
                        verification.media.append(await inspector.inspect(file))
                    } catch {
                        verification.media.append(MediaInspection(file: "output-\(index + 1)", status: .inspectionFailed,
                            detail: "下载或检查未完成，原响应已保留；不要重复生成。"))
                    }
                }
                verification.status = verification.media.contains { $0.status == .suspectedWatermark }
                    ? .suspectedWatermark
                    : verification.media.allSatisfy { $0.status == .noVisibleMarkDetected }
                        ? .noVisibleMarkDetected : .inspectionFailed
                verification.detail = verification.deliverable
                    ? "已完成本机自动检查，未检出常见可见文字水印；请结合各文件的检查范围判断。"
                    : "结果未通过水印检查或检查不完整。请检查已保存的成品，不要自动重复计费调用。"
            }
        } catch {
            verification.status = .inspectionFailed
            verification.detail = "未完成结果检查：\(error.localizedDescription) 请检查已有响应，不要重复生成。"
        }
        do {
            struct Receipt: Codable {
                var profile: String; var model: String; var modelID: String?
                var policy = OutputPolicy.noVisibleWatermark
                var createdAt = Date(); var verification: OutputVerification
            }
            let file = directory.appendingPathComponent("verification.json")
            verification.receiptFile = file.path
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try write(encoder.encode(Receipt(profile: profileAlias, model: model.alias,
                                            modelID: model.modelID, verification: verification)), to: file)
        } catch {
            verification.receiptFile = nil
            verification.status = .inspectionFailed
            verification.detail = "无法保存验收记录；已有响应仍随本次调用返回。请勿重新生成。"
        }
        return verification
    }

    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func values(in object: Any, path: [String]) -> [Any] {
        guard let head = path.first else { return [object] }
        let tail = Array(path.dropFirst())
        if head == "*", let array = object as? [Any] { return array.flatMap { values(in: $0, path: tail) } }
        if let dictionary = object as? [String: Any], let next = dictionary[head] { return values(in: next, path: tail) }
        return []
    }

    private static func hasError(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            if let error = dictionary["error"], !(error is NSNull) { return true }
            return dictionary.values.contains { hasError($0) }
        }
        if let array = object as? [Any] { return array.contains { hasError($0) } }
        return false
    }
}
