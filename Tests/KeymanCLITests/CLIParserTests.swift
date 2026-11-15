import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

@Test
func testParsesCallFromFile() throws {
    #expect(
        try CLIParser.parse([
            "call", "example-ark", "seedream-5-pro",
            "--body", "@request.json", "--json"
        ]) ==
        .call(
            profile: "example-ark",
            model: "seedream-5-pro",
            bodySource: .file("request.json"),
            json: true
        )
    )
}

@Test
func testRejectsUnknownGetCommand() {
    expectThrows { try CLIParser.parse(["get", "example-ark"]) }
}

@Test
func testParsesCallFromStandardInput() throws {
    #expect(try CLIParser.parse(["call", "example-ark", "seedream-5-pro", "--body-stdin"]) ==
        .call(profile: "example-ark", model: "seedream-5-pro", bodySource: .standardInput, json: false))
    #expect(try CLIParser.parse(["call", "example-ark", "seedream-5-pro", "--body-stdin", "--json"]) ==
        .call(profile: "example-ark", model: "seedream-5-pro", bodySource: .standardInput, json: true))
}

@Test(arguments: [
    ["call", "profile", "model", "--body", "@"],
    ["call", "profile", "model", "--body", "@request.json", "--body-stdin"],
    ["call", "profile", "model", "--body-stdin", "unexpected"],
    ["call", "profile", "--body-stdin"],
])
func testRejectsAmbiguousOrIncompleteRequestBody(arguments: [String]) {
    expectThrows { try CLIParser.parse(arguments) }
}
