import Foundation

public enum ConfigurationValidator {
    public static func validate(_ configuration: KeymanConfiguration) throws {
        guard configuration.schemaVersion == KeymanConfiguration.currentSchemaVersion else {
            throw KeymanError.unsupportedSchemaVersion(configuration.schemaVersion)
        }
        var profileAliases = Set<String>()
        var reservedAliases: [String: UUID] = [:]
        for profile in configuration.profiles {
            guard profileAliases.insert(profile.alias).inserted else {
                throw KeymanError.duplicateProfileAlias(profile.alias)
            }
        }
        for profile in configuration.profiles {
            for alias in [profile.alias] + profile.previousAliases {
                try validateAlias(alias)
                if let owner = reservedAliases[alias], owner != profile.id {
                    throw KeymanError.invalidRequest("账号标识或旧标识已被其他账号使用，请选择另一个标识。")
                }
                reservedAliases[alias] = profile.id
            }
        }
        for profile in configuration.profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KeymanError.invalidRequest("账号名称不能为空。")
            }
            try ManagementValidation.authentication(profile.authentication, required: false)
            try validateAlias(profile.alias)
            guard profile.credentialRevision >= 0, profile.credentialRevision < Int.max else {
                throw KeymanError.invalidRequest("凭证修订状态无效。")
            }
            var endpointAliases = Set<String>()
            for endpoint in profile.endpoints {
                try ManagementValidation.endpoint(endpoint)
                try validateAlias(endpoint.alias)
                guard endpointAliases.insert(endpoint.alias).inserted else {
                    throw KeymanError.duplicateEndpointAlias(
                        profile: profile.alias,
                        endpoint: endpoint.alias
                    )
                }
            }
            var modelAliases = Set<String>()
            for model in profile.models {
                if let guide = model.usageGuide { try ModelUsageGuide.validate(guide) }
                guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw KeymanError.invalidRequest("模型名称不能为空。")
                }
                if let capability = model.watermarkCapability {
                    try WatermarkPolicy.validate(capability)
                }
                try validateAlias(model.alias)
                guard modelAliases.insert(model.alias).inserted else {
                    throw KeymanError.duplicateModelAlias(
                        profile: profile.alias,
                        model: model.alias
                    )
                }
                if let template = model.callTemplate {
                    try ManagementValidation.template(template, authentication: profile.authentication)
                    if let paths = template.outputPaths {
                        guard !paths.isEmpty, paths.count <= 16,
                              paths.allSatisfy({ path in
                                  path.split(separator: ".").count <= 12 &&
                                  path.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_-]*(?:\.(?:[A-Za-z_][A-Za-z0-9_-]*|\*))*$/) != nil
                              }) else {
                            throw KeymanError.invalidRequest("返回文件字段需要使用点分路径，例如 data.*.url。")
                        }
                    }
                    guard endpointAliases.contains(template.endpointAlias) else {
                        throw KeymanError.endpointNotFound(
                            profile: profile.alias,
                            endpoint: template.endpointAlias
                        )
                    }
                }
            }
        }
    }

    private static func validateAlias(_ alias: String) throws {
        let aliasPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
        guard alias.wholeMatch(of: aliasPattern) != nil else {
            throw KeymanError.invalidAlias(alias)
        }
    }
}
