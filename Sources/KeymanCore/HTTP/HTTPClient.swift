import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
}

public protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public enum RedirectPolicy {
    public static func allows(from: URL, to: URL) -> Bool {
        from.scheme?.lowercased() == to.scheme?.lowercased()
            && from.host?.lowercased() == to.host?.lowercased()
            && from.port == to.port
    }
}

private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let source = task.currentRequest?.url, let target = request.url,
              RedirectPolicy.allows(from: source, to: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public struct URLSessionHTTPTransport: HTTPTransporting {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(
            configuration: configuration,
            delegate: SafeRedirectDelegate(),
            delegateQueue: nil
        )
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let started = Date()
        var receivedStatus: Int?
        var serverLogID: String?
        do {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KeymanError.networkError("供应商未返回 HTTP 响应")
        }
        receivedStatus = http.statusCode
        serverLogID = http.value(forHTTPHeaderField: "X-Tt-Logid")
        guard response.expectedContentLength <= 96 * 1024 * 1024 else {
            bytes.task.cancel()
            throw KeymanError.networkError("响应超过 96 MiB，已停止接收；请求可能已被处理，请勿自动重试。")
        }
        var data = Data(), buffer = [UInt8]()
        buffer.reserveCapacity(65536)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 65536 {
                    data.append(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                    guard data.count <= 96 * 1024 * 1024 else {
                        throw KeymanError.networkError("响应超过 96 MiB，已停止接收；请求可能已被处理，请勿自动重试。")
                    }
                }
            }
            data.append(contentsOf: buffer)
            guard data.count <= 96 * 1024 * 1024 else {
                throw KeymanError.networkError("响应超过 96 MiB，已停止接收；请求可能已被处理，请勿自动重试。")
            }
        } catch { bytes.task.cancel(); throw error }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as KeymanError {
            throw error
        } catch {
            throw KeymanError.networkError(NetworkFailureDiagnostic.message(
                error, elapsed: Date().timeIntervalSince(started),
                requestID: request.value(forHTTPHeaderField: "X-Api-Request-Id"),
                status: receivedStatus, logID: serverLogID))
        }
    }
}

// Deliberately exclude NSError.userInfo, URLs, request bodies and authentication headers.
public enum NetworkFailureDiagnostic {
    public static func message(_ error: Error, elapsed: TimeInterval,
                               requestID: String? = nil, status: Int? = nil,
                               logID: String? = nil) -> String {
        let e = error as NSError
        func safe(_ value: String?) -> String {
            guard let value, value.count <= 128,
                  value.range(of: "^[A-Za-z0-9_. -]+$", options: .regularExpression) != nil else { return "unknown" }
            return value
        }
        return "domain=\(safe(e.domain)) code=\(e.code) elapsed=\(String(format: "%.3f", elapsed))s requestID=\(safe(requestID)) HTTP=\(status.map(String.init) ?? "unknown") X-Tt-Logid=\(safe(logID)). 请求可能已被供应商处理；不要自动重新生成。"
    }
}
