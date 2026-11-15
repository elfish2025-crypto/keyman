import Foundation
import SwiftUI
import Darwin
import KeymanCore
import KeymanCLI
import KeymanAppSupport

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
if !arguments.isEmpty {
    // Keep the GUI entry synchronous. Starting AppKit inside async_Main holds
    // the main dispatch task open and prevents queued UI work from progressing.
    Task {
        let configurationStore = FileConfigurationStore()
        let credentialStore = KeychainCredentialStore(configurationStore: configurationStore)
        let app = CLIApplication(
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            modelCaller: ModelCaller(
                configurationStore: configurationStore,
                credentialStore: credentialStore
            ),
            commandRunner: ProcessCommandRunner(),
            legacyImporter: LegacyImporter()
        )
        if Array(arguments) == ["mcp"] {
            await MCPServer.run(application: app)
            exit(0)
        }
        let result = await app.execute(
            arguments: Array(arguments),
            stdin: { FileHandle.standardInput.readDataToEndOfFile() }
        )
        FileHandle.standardOutput.write(result.stdout)
        FileHandle.standardError.write(result.stderr)
        exit(result.exitCode)
    }
    dispatchMain()
}

KeymanMenuBarApplication.main()
