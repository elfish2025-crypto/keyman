import Foundation
import Testing
@testable import KeymanCore

@Test
func testBuildInjectsModelAndAuthenticationWithoutAllowingHostOverride() throws {
    let profile = ProviderProfile.fixture(alias: "example-ark")
    let model = ModelRecord.seedreamFixture
    let body = Data(#"{"prompt":"cinematic shop"}"#.utf8)

    let request = try KeymanRequestBuilder().build(
        profile: profile,
        model: model,
        secret: "unit-test-credential",
        body: body
    )

    #expect(
        request.url?.absoluteString ==
        "https://ark.cn-beijing.volces.com/api/v3/images/generations"
    )
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-credential")
    let httpBody = try #require(request.httpBody)
    let object = try JSONSerialization.jsonObject(with: httpBody)
    let json = try #require(object as? [String: Any])
    #expect(json["model"] as? String == "doubao-seedream-5-0-pro-260628")
}

@Test
func testRejectsAbsoluteTemplatePath() {
    var model = ModelRecord.seedreamFixture
    model.callTemplate?.path = "https://example.invalid/steal"

    expectThrows {
        try KeymanRequestBuilder().build(
            profile: .fixture(alias: "example-ark"),
            model: model,
            secret: "unit-test-credential",
            body: Data("{}".utf8)
        )
    }
}

@Test
func collidingStaticAuthHeaderIsRejectedBeforeSending() throws {
    let profile = ProviderProfile.fixture(alias: "example-ark")
    var template = CallTemplate.httpFixture
    template.staticHeaders = [profile.authentication.headerName: "should-not-win"]
    var model = ModelRecord.seedreamFixture
    model.callTemplate = template
    model.watermarkCapability = WatermarkCapability(disposition: .configurable,
        parameterPath: "watermark", disabledValue: .bool(false), evidence: "Test contract",
        contractFingerprint: WatermarkPolicy.fingerprint(profile: profile, model: model))

    #expect(throws: KeymanError.self) { try KeymanRequestBuilder().build(
        profile: profile,
        model: model,
        secret: "unit-test-credential",
        body: Data(#"{"prompt":"cinematic shop"}"#.utf8)
    ) }
}
