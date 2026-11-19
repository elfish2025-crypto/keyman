import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case volcengineArk = "volcengine-ark"
    case alibabaBailian = "alibaba-bailian"
    case customREST = "custom-rest"
}

public enum ModelModality: String, Codable, CaseIterable, Sendable {
    case text, image, video, speech
    case voiceDesign = "voice-design"
    case other
}

public enum ModelStatus: String, Codable, CaseIterable, Sendable {
    case candidate, declared, verified, unavailable
    public var isCallable: Bool { self == .declared || self == .verified }
}

public enum HTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct EndpointRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var alias: String
    public var name: String
    public var baseURL: URL

    public init(id: UUID, alias: String, name: String, baseURL: URL) {
        self.id = id
        self.alias = alias
        self.name = name
        self.baseURL = baseURL
    }
}

public struct AuthenticationConfiguration: Codable, Equatable, Sendable {
    public var headerName: String
    public var prefix: String
    public var environmentVariable: String

    public init(headerName: String, prefix: String, environmentVariable: String) {
        self.headerName = headerName
        self.prefix = prefix
        self.environmentVariable = environmentVariable
    }
}

public struct CallTemplate: Codable, Equatable, Sendable {
    public var endpointAlias: String
    public var method: HTTPMethod
    public var path: String
    public var modelIDBodyField: String?
    public var staticHeaders: [String: String]
    public var requestFields: [String]
    public var isAsync: Bool
    public var outputPaths: [String]?
    public var responseFormat: CallResponseFormat?
    public var uuidHeaders: [String]?
    public var requiredBodyFields: [String]?
    public var taskQuery: TaskQueryTemplate?

    public init(
        endpointAlias: String,
        method: HTTPMethod,
        path: String,
        modelIDBodyField: String?,
        staticHeaders: [String: String],
        requestFields: [String],
        isAsync: Bool,
        outputPaths: [String]? = nil,
        responseFormat: CallResponseFormat? = nil,
        uuidHeaders: [String]? = nil,
        requiredBodyFields: [String]? = nil,
        taskQuery: TaskQueryTemplate? = nil
    ) {
        self.endpointAlias = endpointAlias
        self.method = method
        self.path = path
        self.modelIDBodyField = modelIDBodyField
        self.staticHeaders = staticHeaders
        self.requestFields = requestFields
        self.isAsync = isAsync
        self.outputPaths = outputPaths
        self.responseFormat = responseFormat
        self.uuidHeaders = uuidHeaders
        self.requiredBodyFields = requiredBodyFields
        self.taskQuery = taskQuery
    }
}

public struct ModelRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var alias: String
    public var name: String
    public var modelID: String?
    public var modality: ModelModality
    public var status: ModelStatus
    public var callTemplate: CallTemplate?
    public var sourceFile: String?
    public var lastVerifiedAt: Date?
    public var watermarkCapability: WatermarkCapability?
    public var usageGuide: ModelUsageGuide?
    public var isEnabled: Bool

    public var hasRequiredModelID: Bool {
        callTemplate != nil && (callTemplate?.modelIDBodyField == nil || modelID?.isEmpty == false)
    }

    public init(
        id: UUID,
        alias: String,
        name: String,
        modelID: String?,
        modality: ModelModality,
        status: ModelStatus,
        callTemplate: CallTemplate?,
        sourceFile: String?,
        lastVerifiedAt: Date?,
        watermarkCapability: WatermarkCapability? = nil,
        isEnabled: Bool = true,
        usageGuide: ModelUsageGuide? = nil
    ) {
        self.id = id
        self.alias = alias
        self.name = name
        self.modelID = modelID
        self.modality = modality
        self.status = status
        self.callTemplate = callTemplate
        self.sourceFile = sourceFile
        self.lastVerifiedAt = lastVerifiedAt
        self.watermarkCapability = watermarkCapability
        self.isEnabled = isEnabled
        self.usageGuide = usageGuide
    }

    private enum CodingKeys: String, CodingKey {
        case id, alias, name, modelID, modality, status, callTemplate, sourceFile, lastVerifiedAt, watermarkCapability, isEnabled, usageGuide
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        alias = try c.decode(String.self, forKey: .alias)
        name = try c.decode(String.self, forKey: .name)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        modality = try c.decode(ModelModality.self, forKey: .modality)
        status = try c.decode(ModelStatus.self, forKey: .status)
        callTemplate = try c.decodeIfPresent(CallTemplate.self, forKey: .callTemplate)
        sourceFile = try c.decodeIfPresent(String.self, forKey: .sourceFile)
        lastVerifiedAt = try c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        watermarkCapability = try c.decodeIfPresent(WatermarkCapability.self, forKey: .watermarkCapability)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        usageGuide = try c.decodeIfPresent(ModelUsageGuide.self, forKey: .usageGuide)
    }
}

public struct ProviderProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var alias: String
    public var name: String
    public var provider: ProviderKind
    public var project: String?
    public var region: String?
    public var workspaceName: String?
    public var workspaceID: String?
    public var endpoints: [EndpointRecord]
    public var authentication: AuthenticationConfiguration
    public var notes: String?
    public var sourceFiles: [String]
    public var models: [ModelRecord]
    public var lastTestedAt: Date?
    public var lastTestSucceeded: Bool?
    public var isEnabled: Bool
    public var previousAliases: [String]
    public var credentialRevision: Int
    public var usesCredentialVault: Bool
    /// Optional link to the provider's balance page; opened in the browser only.
    public var balanceURL: URL?

    public init(
        id: UUID,
        alias: String,
        name: String,
        provider: ProviderKind,
        project: String?,
        region: String?,
        workspaceName: String?,
        workspaceID: String?,
        endpoints: [EndpointRecord],
        authentication: AuthenticationConfiguration,
        notes: String?,
        sourceFiles: [String],
        models: [ModelRecord],
        lastTestedAt: Date?,
        lastTestSucceeded: Bool?,
        isEnabled: Bool = true,
        previousAliases: [String] = [],
        credentialRevision: Int = 0,
        usesCredentialVault: Bool = false,
        balanceURL: URL? = nil
    ) {
        self.id = id
        self.alias = alias
        self.name = name
        self.provider = provider
        self.project = project
        self.region = region
        self.workspaceName = workspaceName
        self.workspaceID = workspaceID
        self.endpoints = endpoints
        self.authentication = authentication
        self.notes = notes
        self.sourceFiles = sourceFiles
        self.models = models
        self.lastTestedAt = lastTestedAt
        self.lastTestSucceeded = lastTestSucceeded
        self.isEnabled = isEnabled
        self.previousAliases = previousAliases
        self.credentialRevision = credentialRevision
        self.usesCredentialVault = usesCredentialVault
        self.balanceURL = balanceURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, alias, name, provider, project, region, workspaceName, workspaceID, endpoints
        case authentication, notes, sourceFiles, models, lastTestedAt, lastTestSucceeded, isEnabled, previousAliases, credentialRevision
        case usesCredentialVault, balanceURL
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        alias = try c.decode(String.self, forKey: .alias)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(ProviderKind.self, forKey: .provider)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        endpoints = try c.decode([EndpointRecord].self, forKey: .endpoints)
        authentication = try c.decode(AuthenticationConfiguration.self, forKey: .authentication)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        sourceFiles = try c.decode([String].self, forKey: .sourceFiles)
        models = try c.decode([ModelRecord].self, forKey: .models)
        lastTestedAt = try c.decodeIfPresent(Date.self, forKey: .lastTestedAt)
        lastTestSucceeded = try c.decodeIfPresent(Bool.self, forKey: .lastTestSucceeded)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        previousAliases = try c.decodeIfPresent([String].self, forKey: .previousAliases) ?? []
        credentialRevision = try c.decodeIfPresent(Int.self, forKey: .credentialRevision) ?? 0
        usesCredentialVault = try c.decodeIfPresent(Bool.self, forKey: .usesCredentialVault) ?? false
        balanceURL = try c.decodeIfPresent(URL.self, forKey: .balanceURL)
    }
}

public struct KeymanConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 6
    public var schemaVersion: Int = currentSchemaVersion
    public var profiles: [ProviderProfile]
    public var outputPolicy: OutputPolicy

    public init(profiles: [ProviderProfile], outputPolicy: OutputPolicy = .noVisibleWatermark) {
        self.profiles = profiles
        self.outputPolicy = outputPolicy
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, profiles, outputPolicy }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw KeymanError.unsupportedSchemaVersion(version)
        }
        schemaVersion = Self.currentSchemaVersion
        profiles = try values.decode([ProviderProfile].self, forKey: .profiles)
        outputPolicy = try values.decodeIfPresent(OutputPolicy.self, forKey: .outputPolicy)
            ?? .noVisibleWatermark
    }
}
