import Foundation
import Testing
@testable import KeymanCore

@Suite
struct ManagementConcurrencyTests {
    @Test
    func separateFileStoresRejectLostUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let a = FileConfigurationStore(fileURL: url)
        let b = FileConfigurationStore(fileURL: url)
        let original = KeymanConfiguration(profiles: [.fixture(alias: "original")])
        try await a.save(original)
        var first = original; first.profiles.append(.fixture(alias: "first"))
        var second = original; second.profiles.append(.fixture(alias: "second"))
        let firstDraft = first; let secondDraft = second
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask { do { try await a.save(firstDraft, replacing: original); return true } catch { return false } }
            group.addTask { do { try await b.save(secondDraft, replacing: original); return true } catch { return false } }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(outcomes.filter { $0 }.count == 1)
        let saved = try await a.load()
        #expect(saved == first || saved == second)
        #expect(saved.profiles.first == original.profiles.first)
    }

    @Test
    func fileCredentialTransactionsSerializeAcrossStoreInstances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let activity = ActiveMutationCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let store = FileConfigurationStore(fileURL: url)
                    try await store.withCredentialMutation {
                        await activity.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await activity.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await activity.maximum == 1)
        #expect(await activity.completed == 6)
    }

    @Test
    func simultaneousKeyReplacementCannotOverwriteWinningCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let profile = ProviderProfile.fixture(alias: "account")
        let store = FileConfigurationStore(fileURL: url)
        try await store.save(.init(profiles: [profile]))
        let keys = InMemoryCredentialStore()
        await keys.save("old-synthetic-key", for: profile.id)
        let winners = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for value in ["first-synthetic-key", "second-synthetic-key"] {
                group.addTask {
                    let manager = KeymanManager(configurationStore: FileConfigurationStore(fileURL: url), credentialStore: keys)
                    do { try await manager.setCredential(profile.alias, secret: value, expectedProfile: profile); return value }
                    catch KeymanError.configurationChanged { return nil }
                    catch { Issue.record("Unexpected error: \(error)"); return nil }
                }
            }
            var results: [String] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        #expect(winners.count == 1)
        #expect(try await keys.load(for: profile.id) == winners.first)
        #expect(try await store.load().profiles[0].credentialRevision == 1)
    }

    @Test
    func schemaTwoMigrationPreservesAccountsModelsAndOutputPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("config.json")
        let original = KeymanConfiguration(profiles: [.fixture(alias: "old", models: [.seedreamFixture])], outputPolicy: .providerDefault)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object["schemaVersion"] = 2
        var profiles = object["profiles"] as! [[String: Any]]
        profiles[0].removeValue(forKey: "isEnabled")
        profiles[0].removeValue(forKey: "previousAliases")
        profiles[0].removeValue(forKey: "credentialRevision")
        var models = profiles[0]["models"] as! [[String: Any]]
        models[0].removeValue(forKey: "isEnabled"); profiles[0]["models"] = models
        object["profiles"] = profiles
        let oldData = try JSONSerialization.data(withJSONObject: object)
        try oldData.write(to: file)
        let store = FileConfigurationStore(fileURL: file)
        let migrated = try await store.load()
        #expect(migrated == original)
        #expect(try Data(contentsOf: file) == oldData)
        try await store.save(migrated, replacing: migrated)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "backup" })
        #expect(try Data(contentsOf: backup) == oldData)
        for url in [file, backup] {
            #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }
}

private actor ActiveMutationCounter {
    var active = 0
    private(set) var maximum = 0
    private(set) var completed = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1; completed += 1 }
}
