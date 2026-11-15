import Foundation
import KeymanCore

public enum BodySource: Equatable, Sendable {
    case file(String)
    case standardInput
}

public enum CLICommand: Equatable, Sendable {
    case management(ManagementCommand)
    case catalog(query: String?, json: Bool)
    case guide(profile: String, model: String, json: Bool)
    case example(profile: String, model: String)
    case installGuides(dryRun: Bool)
    case vaultStatus(unlock: Bool)
    case migrateVault(source: String?, dryRun: Bool)
    case list(json: Bool)
    case profile(profile: String, json: Bool)
    case models(profile: String, json: Bool)
    case inspect(profile: String, model: String, json: Bool)
    case call(profile: String, model: String, bodySource: BodySource, json: Bool)
    case task(profile: String, model: String, id: String, waitSeconds: Int)
    case guardedCall(profile: String, model: String, bodySource: BodySource, allowWatermark: Bool, preflight: Bool)
    case run(profile: String, command: [String])
    case uncheckedRun(profile: String, command: [String])
    case verify(paths: [String])
    case verifyResponse(profile: String, model: String, file: String)
    case policy(OutputPolicy?)
    case configureWatermark(profile: String, model: String, file: String)
    case importPreview(path: String, json: Bool)
    case importCommit(path: String, json: Bool)
    case importCheck(path: String, json: Bool)
    case help
}
