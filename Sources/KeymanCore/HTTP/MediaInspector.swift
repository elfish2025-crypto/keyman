import Foundation
import Vision
import ImageIO
import AVFoundation
import CryptoKit

public enum InspectionStatus: String, Codable, Sendable {
    case noVisibleMarkDetected = "no-visible-mark-detected"
    case suspectedWatermark = "suspected-watermark"
    case inspectionFailed = "inspection-failed"
    case pending = "pending-verification"
}

public struct MediaInspection: Codable, Equatable, Sendable {
    public var file: String
    public var status: InspectionStatus
    public var inspectedFrames: Int
    public var findings: [String]
    public var sha256: String?
    public var detail: String

    public init(file: String, status: InspectionStatus, inspectedFrames: Int = 0,
                findings: [String] = [], sha256: String? = nil, detail: String) {
        self.file = file; self.status = status; self.inspectedFrames = inspectedFrames
        self.findings = findings; self.sha256 = sha256; self.detail = detail
    }
}

public protocol MediaInspecting: Sendable {
    func inspect(_ url: URL) async -> MediaInspection
}

/// Local OCR is a supplementary check, not a proof that every possible logo is absent.
public struct LocalMediaInspector: MediaInspecting {
    public init() {}

    public func inspect(_ url: URL) async -> MediaInspection {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0, size.int64Value <= 200 * 1024 * 1024 else {
                throw KeymanError.invalidRequest("结果必须为 200 MiB 以内的本机图片或视频文件。")
            }
            let digest = try Self.hash(url)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
                guard CGImageSourceGetCount(source) == 1 else {
                    throw KeymanError.invalidRequest("多帧图片尚不能完整检查，请交由 Agent 继续检查。")
                }
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceThumbnailMaxPixelSize: 4096,
                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                    throw KeymanError.invalidRequest("图片不能解码。")
                }
                let findings = try Self.recognize(image)
                return result(url, digest: digest, frames: 1, findings: findings,
                              detail: "已用本机 OCR 检查常见 AI 文字水印及边缘供应商名称；纯图形、隐形或无法识别的标记不在此检查保证范围内。")
            }
            // ImageIO can return a non-nil source with zero frames for an MP4.
            // Let AVFoundation sniff the content, including extensionless downloads.
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 180 else {
                throw KeymanError.invalidRequest("视频自动检查支持 180 秒以内；当前结果需要进一步检查。")
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 2048, height: 2048)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
            var times = Array(stride(from: 0.0, to: duration, by: 2.0))
            if let last = times.last, duration - last > 0.2 { times.append(max(0, duration - 0.1)) }
            var findings: [String] = []
            for time in times {
                let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                findings += try Self.recognize(frame.image).map { "\(String(format: "%.1f", time))s: \($0)" }
            }
            return result(url, digest: digest, frames: times.count, findings: findings,
                          detail: "已检查首尾及约每 2 秒的抽样帧；抽样可能漏掉短暂出现的水印，纯图形和隐形标记不在 OCR 保证范围内。")
        } catch {
            return MediaInspection(file: url.path, status: .inspectionFailed,
                                   detail: "未完成检查：\(error.localizedDescription)")
        }
    }

    private func result(_ url: URL, digest: String, frames: Int, findings: [String], detail: String) -> MediaInspection {
        MediaInspection(file: url.path,
                        status: findings.isEmpty ? .noVisibleMarkDetected : .suspectedWatermark,
                        inspectedFrames: frames, findings: Array(Set(findings)).sorted(), sha256: digest, detail: detail)
    }

    private static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func recognize(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.005
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch { throw KeymanError.invalidRequest("本机文字识别服务不可用，尚未完成检查。") }
        // OCR commonly confuses the I in AI with lowercase l or the digit 1.
        let labels = ["ai生成", "a1生成", "al生成", "人工智能生成", "aigenerated", "algenerated", "a1generated",
                      "generatedbyai", "generatedbyal", "generatedbya1", "aigc"]
        let brands: Set<String> = ["seedream", "seedance", "vidu", "runway", "kling", "即梦", "可灵", "豆包", "sora", "万相"]
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let normalized = candidate.string.lowercased().filter { $0.isLetter || $0.isNumber }
            let box = observation.boundingBox
            let atEdge = box.minY < 0.18 || box.maxY > 0.82 || box.minX < 0.15 || box.maxX > 0.85
            guard labels.contains(where: { normalized.contains($0) })
                    || (atEdge && brands.contains(normalized)) else { return nil }
            return "疑似标记：\(candidate.string)"
        }
    }
}
