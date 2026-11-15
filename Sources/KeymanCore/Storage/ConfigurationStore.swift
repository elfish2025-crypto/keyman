import Foundation
import Darwin

public protocol ConfigurationStoring: Sendable {
    func load() async throws -> KeymanConfiguration
    func save(_ configuration: KeymanConfiguration) async throws
    func save(_ configuration: KeymanConfiguration, replacing expected: KeymanConfiguration) async throws
    func withCredentialMutation<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T
}

public extension ConfigurationStoring {
    func withCredentialMutation<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await CredentialMutationQueue.shared.run(operation)
    }

    func save(_ configuration: KeymanConfiguration, replacing expected: KeymanConfiguration) async throws {
        guard try await load() == expected else { throw KeymanError.configurationChanged }
        try await save(configuration)
    }
}

public actor FileConfigurationStore: ConfigurationStoring {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Keyman", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = FileConfigurationStore.defaultURL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() async throws -> KeymanConfiguration {
        try readConfiguration()
    }

    private func readConfiguration() throws -> KeymanConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return KeymanConfiguration(profiles: [])
        }
        let data = try Data(contentsOf: fileURL)
        let configuration = try decoder.decode(KeymanConfiguration.self, from: data)
        try ConfigurationValidator.validate(configuration)
        return configuration
    }

    public func save(_ configuration: KeymanConfiguration) async throws {
        try withWriteLock { try persist(configuration) }
    }

    public func save(_ configuration: KeymanConfiguration, replacing expected: KeymanConfiguration) async throws {
        try withWriteLock {
            guard try readConfiguration() == expected else { throw KeymanError.configurationChanged }
            try persist(configuration)
        }
    }

    /// Separate from the short configuration write lock: Keychain authorization may suspend.
    public func withCredentialMutation<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(fileURL.path + ".credentials.lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw KeymanError.invalidRequest("无法锁定凭证管理操作。") }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw KeymanError.invalidRequest("无法锁定凭证管理操作。")
            }
            guard ContinuousClock.now < deadline else {
                throw KeymanError.invalidRequest("另一个凭证管理操作尚未完成。请处理钥匙串授权或等待其结束后重试。")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func withWriteLock(_ operation: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(fileURL.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw KeymanError.invalidRequest("无法锁定本机配置文件。") }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw KeymanError.invalidRequest("无法锁定本机配置文件。") }
        try operation()
    }

    private func persist(_ configuration: KeymanConfiguration) throws {
        try ConfigurationValidator.validate(configuration)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(configuration)
        if let previous = try? Data(contentsOf: fileURL),
           let object = try? JSONSerialization.jsonObject(with: previous) as? [String: Any],
           let version = object["schemaVersion"] as? Int, version < KeymanConfiguration.currentSchemaVersion {
            let backup = directory.appendingPathComponent("config.schema\(version).\(UUID().uuidString).backup")
            try privateWrite(previous, to: backup)
        }
        let temporary = directory.appendingPathComponent(".config.\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try privateWrite(data, to: temporary)
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw KeymanError.invalidRequest("无法保存配置，原文件保持不变。")
        }
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw KeymanError.invalidRequest("无法创建私有配置文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

private actor CredentialMutationQueue {
    static let shared = CredentialMutationQueue()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
