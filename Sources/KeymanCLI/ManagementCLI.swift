import Foundation
import KeymanCore

public enum ManagementEntity: String, Equatable, Sendable { case profile, model, endpoint, key }
public enum ManagementAction: String, Equatable, Sendable { case add, update, delete, enable, disable, get, list, set, clear, status, test, move }

public struct ManagementCommand: Equatable, Sendable {
    public var entity: ManagementEntity
    public var action: ManagementAction
    public var profileAlias: String?
    public var itemAlias: String?
    public var documentPath: String?
    public var keySource: BodySource?
    public var dryRun: Bool
    public var destinationAlias: String? = nil
}

enum ManagementCLIParser {
    static func parse(_ args: [String]) throws -> ManagementCommand {
        guard args.count >= 2, let entity = ManagementEntity(rawValue: args[0]),
              let action = ManagementAction(rawValue: args[1]) else { throw usage() }
        let supported: [ManagementEntity: Set<ManagementAction>] = [
            .profile: [.add, .update, .delete, .enable, .disable, .get, .list, .test],
            .model: [.add, .update, .delete, .enable, .disable, .get, .list, .move],
            .endpoint: [.add, .update, .delete, .get, .list],
            .key: [.set, .clear, .status]
        ]
        guard supported[entity]?.contains(action) == true else { throw usage() }
        var positional: [String] = []; var document: String?; var keySource: BodySource?; var dryRun = false
        var options = Set<String>(); var i = 2
        while i < args.count {
            let value = args[i]
            if value.hasPrefix("--") {
                guard options.insert(value).inserted else { throw usage() }
                switch value {
                case "--json": break
                case "--dry-run": dryRun = true
                case "--key-stdin":
                    guard keySource == nil else { throw usage() }
                    keySource = .standardInput
                case "--file", "--key-file":
                    i += 1
                    guard i < args.count, !args[i].isEmpty, !args[i].hasPrefix("--") else { throw usage() }
                    if value == "--file" { document = args[i] }
                    else { guard keySource == nil else { throw usage() }; keySource = .file(args[i]) }
                default: throw usage() // Never echo a potential secret supplied as an option.
                }
            } else { positional.append(value) }
            i += 1
        }
        let count: Int
        switch (entity, action) {
        case (.model, .move): count = 3
        case (.profile, .add), (.profile, .list): count = 0
        case (.profile, _), (.key, _), (.model, .add), (.model, .list), (.endpoint, .add), (.endpoint, .list): count = 1
        default: count = 2
        }
        guard positional.count == count,
              (document != nil) == (action == .add || action == .update || action == .move),
              keySource == nil || ((entity == .profile && action == .add) || (entity == .key && action == .set)),
              !(entity == .key && action == .set && keySource == nil),
              !(dryRun && [.get, .list, .status, .test].contains(action)) else { throw usage() }
        return .init(entity: entity, action: action, profileAlias: positional.first,
                     itemAlias: positional.count > 1 ? positional[1] : nil,
                     documentPath: document, keySource: keySource, dryRun: dryRun,
                     destinationAlias: action == .move ? positional[2] : nil)
    }

    private static func usage() -> KeymanError {
        .invalidRequest("管理命令参数不正确。请运行 keyman help；配置使用 --file，Key 只通过 --key-stdin 或 --key-file 输入。")
    }
}

extension CLIApplication {
    func manage(_ command: ManagementCommand, document: Data? = nil, stdin: @Sendable () async throws -> Data) async throws -> CLIResult {
        let manager = KeymanManager(configurationStore: configurationStore, credentialStore: credentialStore)
        let alias = command.profileAlias ?? ""
        let item = command.itemAlias ?? ""
        let data = try document ?? command.documentPath.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let secret: String?
        if let source = command.keySource {
            let raw: Data
            switch source {
            case .standardInput: raw = try await stdin()
            case .file(let path): raw = try Data(contentsOf: URL(fileURLWithPath: path))
            }
            guard let string = String(data: raw, encoding: .utf8) else { throw KeymanError.invalidRequest("Key 文件必须为 UTF-8 文本。") }
            secret = string
        } else { secret = nil }
        let result: ManagementResult
        switch (command.entity, command.action) {
        case (.profile, .get): return CLIOutput.profile(try await manager.profile(alias), json: true)
        case (.profile, .list): return CLIOutput.profiles(try await configurationStore.load().profiles, json: true)
        case (.profile, .test):
            let state = try await ProfileTester(configurationStore: configurationStore, credentialStore: credentialStore).test(profileAlias: alias)
            struct Result: Encodable { var ok = true; var profile: String; var result: ProfileTestResult }
            return CLIOutput.encoded(Result(profile: alias, result: state))
        case (.profile, .add):
            result = try await manager.saveProfile(ManagementDocuments.profile(data!), secret: secret, dryRun: command.dryRun)
        case (.profile, .update):
            let original = try await manager.profile(alias)
            result = try await manager.saveProfile(ManagementDocuments.profile(data!, existing: original), original: original, dryRun: command.dryRun)
        case (.profile, .enable), (.profile, .disable):
            result = try await manager.setProfileEnabled(alias, enabled: command.action == .enable, dryRun: command.dryRun)
        case (.profile, .delete): result = try await manager.deleteProfile(alias, dryRun: command.dryRun)
        case (.key, .status): return CLIOutput.encoded(try await manager.credentialStatus(alias))
        case (.key, .set), (.key, .clear):
            result = try await manager.setCredential(alias, secret: secret, dryRun: command.dryRun)
        case (.model, .list):
            let profile = try await manager.profile(alias)
            return CLIOutput.models(profile.models.map { resolvedModel($0, profile: profile) }, json: true)
        case (.model, .get):
            let profile = try await manager.profile(alias)
            guard let model = profile.models.first(where: { $0.alias == item }) else { throw KeymanError.modelNotFound(item) }
            return CLIOutput.model(resolvedModel(model, profile: profile), json: true)
        case (.model, .add), (.model, .update):
            let profile = try await manager.profile(alias)
            let original: ModelRecord?
            if command.action == .update {
                guard let existing = profile.models.first(where: { $0.alias == item }) else { throw KeymanError.modelNotFound(item) }
                original = existing
            } else { original = nil }
            let document = try JSONSerialization.jsonObject(with: data!) as? [String: Any]
            let confirmsExample = (document?["usageGuide"] as? [String: Any])?["requestExample"] != nil
            result = try await manager.saveModel(ManagementDocuments.model(data!, existing: original), profileAlias: alias,
                original: original, expectedProfile: profile, confirmUsageExample: confirmsExample, dryRun: command.dryRun)
        case (.model, .delete): result = try await manager.deleteModel(item, profileAlias: alias, dryRun: command.dryRun)
        case (.model, .move):
            result = try await manager.moveModel(item, from: alias, to: command.destinationAlias!, patch: data!, dryRun: command.dryRun)
        case (.model, .enable), (.model, .disable):
            result = try await manager.setModelEnabled(item, profileAlias: alias, enabled: command.action == .enable, dryRun: command.dryRun)
        case (.endpoint, .get), (.endpoint, .list):
            let profile = try await manager.profile(alias)
            if command.action == .get {
                guard let endpoint = profile.endpoints.first(where: { $0.alias == item }) else { throw KeymanError.endpointNotFound(profile: alias, endpoint: item) }
                return CLIOutput.encoded(endpoint)
            }
            return CLIOutput.encoded(profile.endpoints)
        case (.endpoint, .add), (.endpoint, .update):
            let profile = try await manager.profile(alias)
            let original: EndpointRecord?
            if command.action == .update {
                guard let existing = profile.endpoints.first(where: { $0.alias == item }) else { throw KeymanError.endpointNotFound(profile: alias, endpoint: item) }
                original = existing
            } else { original = nil }
            result = try await manager.saveEndpoint(ManagementDocuments.endpoint(data!, existing: original), profileAlias: alias,
                originalAlias: original?.alias, expectedProfile: profile, dryRun: command.dryRun)
        case (.endpoint, .delete): result = try await manager.deleteEndpoint(item, profileAlias: alias, dryRun: command.dryRun)
        default: throw KeymanError.invalidRequest("不支持的管理操作。")
        }
        return CLIOutput.encoded(result)
    }
}
