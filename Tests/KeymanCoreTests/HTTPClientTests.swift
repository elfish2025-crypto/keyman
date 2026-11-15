import Foundation
import Testing
@testable import KeymanCore

@Test
func testRedirectPolicyRejectsCrossHostRedirect() {
    #expect(
        !RedirectPolicy.allows(
            from: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
            to: URL(string: "https://example.invalid/collect")!
        )
    )
}

@Test func boundedTransportReadsAllSSESegmentsWithoutRetry() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingFixtureProtocol.self]
    let transport = URLSessionHTTPTransport(configuration: configuration)
    let response = try await transport.send(URLRequest(url: URL(string: "https://fixture.invalid/sse")!))
    #expect(response.statusCode == 200)
    let audio = try VolcengineSSEAudio.decode(response.body)
    #expect(audio.bytes == Data("abcdef".utf8))
}

@Test func transportRejectsOversizedResponseHeader() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingFixtureProtocol.self]
    let transport = URLSessionHTTPTransport(configuration: configuration)
    do {
        _ = try await transport.send(URLRequest(url: URL(string: "https://fixture.invalid/oversized")!))
        Issue.record("Expected size limit")
    } catch KeymanError.networkError { }
}

private final class StreamingFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let text = "data: {\"code\":0,\"data\":\"YWJj\"}\n\ndata: {\"code\":0,\"data\":\"ZGVm\"}\n\ndata: {\"code\":20000000}\n\n"
        let length = request.url?.path == "/oversized" ? 100 * 1024 * 1024 : text.utf8.count
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream", "Content-Length": "\(length)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for piece in text.utf8 { client?.urlProtocol(self, didLoad: Data([piece])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
