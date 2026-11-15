import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

@Test
func testListDoesNotReadCredentialStore() async throws {
    let app = CLIApplication(
        configurationStore: InMemoryConfigurationStore(),
        credentialStore: FailingCredentialStore(),
        modelCaller: StubModelCaller(),
        commandRunner: StubCommandRunner(),
        legacyImporter: StubLegacyImporter()
    )

    let result = await app.execute(arguments: ["list", "--json"], stdin: { Data() })

    #expect(result.exitCode == 0)
    #expect(!String(decoding: result.stdout, as: UTF8.self).contains("unit-test-credential"))
}
