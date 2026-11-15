import Foundation

public enum ProfileTestResult: String, Codable, Sendable, Equatable {
    case localOnly = "local-only"
    case remoteAuthenticated = "remote-authenticated"
}

public protocol ProfileTesting: Sendable {
    func test(profileAlias: String) async throws -> ProfileTestResult
}

public struct ProfileTester: ProfileTesting {
    private let configurationStore: any ConfigurationStoring
    private let credentialStore: any CredentialStoring
    private let transport: any HTTPTransporting

    public init(
        configurationStore: any ConfigurationStoring,
        credentialStore: any CredentialStoring,
        transport: any HTTPTransporting = URLSessionHTTPTransport()
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.transport = transport
    }

    public func test(profileAlias: String) async throws -> ProfileTestResult {
        let configuration = try await configurationStore.load()
        guard let profile = configuration.profiles.first(where: { $0.alias == profileAlias }) else {
            throw KeymanError.profileNotFound(profileAlias)
        }
        guard profile.isEnabled else { throw KeymanError.profileDisabled(profile.alias) }
        let secret = try await credentialStore.load(for: profile.id)
        guard profile.provider == .alibabaBailian,
              let endpoint = profile.endpoints.first(where: { $0.alias == "openai" }) else {
            return .localOnly
        }
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)
        components?.path += "/models"
        guard let url = components?.url else {
            throw KeymanError.invalidRequest("无法构建百炼模型列表地址")
        }
        var request = URLRequest(url: url)
        try ManagementValidation.authentication(profile.authentication, required: true)
        request.httpMethod = "GET"
        request.setValue(
            profile.authentication.prefix.isEmpty ? secret : "\(profile.authentication.prefix) \(secret)",
            forHTTPHeaderField: profile.authentication.headerName
        )
        let response = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: return .remoteAuthenticated
        case 401, 403: throw ProviderResponseValidation.authenticationError(status: response.statusCode, body: CredentialRedactor.redact(response.body, secret: secret))
        case 429: throw KeymanError.rateLimited
        default:
            throw KeymanError.providerError(
                status: response.statusCode,
                message: "非计费配置测试失败"
            )
        }
    }
}
