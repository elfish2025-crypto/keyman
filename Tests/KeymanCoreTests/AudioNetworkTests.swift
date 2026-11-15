import Foundation
import Testing
@testable import KeymanCore

@Test func synchronousAudioHasLongTimeout() throws {
    let profile = ProviderProfile.fixture(alias: "test")
    var model = ModelRecord.seedreamFixture
    model.modality = .speech
    model.callTemplate?.responseFormat = .json
    let request = try KeymanRequestBuilder().build(profile: profile, model: model,
        secret: "test-secret", body: Data("{}".utf8))
    #expect(request.timeoutInterval == 300)
}

@Test func networkDiagnosticKeepsCodeButNotSensitiveUserInfo() {
    let error = NSError(domain: NSURLErrorDomain, code: -1005,
        userInfo: [NSLocalizedDescriptionKey: "secret-token", NSURLErrorFailingURLStringErrorKey: "https://secret.invalid/?key=secret-token"])
    let text = NetworkFailureDiagnostic.message(error, elapsed: 13, requestID: "test-id", status: 200, logID: "trace123")
    #expect(text.contains("code=-1005"))
    #expect(text.contains("HTTP=200"))
    #expect(text.contains("trace123"))
    #expect(!text.contains("secret"))
}
