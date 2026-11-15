import Foundation
import KeymanCore

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let verb = arguments.first else { return .help }
        if ["model", "endpoint", "key"].contains(verb)
            || (verb == "profile" && (arguments.dropFirst().filter { $0 != "--json" }.count > 1
                || arguments.dropFirst().first == "list" || arguments.dropFirst().first == "add")) {
            return .management(try ManagementCLIParser.parse(arguments))
        }
        let json = arguments.contains("--json")
        let positional = arguments.dropFirst().filter { $0 != "--json" }
        switch verb {
        case "vault":
            let values = Array(positional)
            if values == ["status"] || values == ["unlock"] { return .vaultStatus(unlock: values[0] == "unlock") }
            let dryRun = values.contains("--dry-run")
            let args = values.filter { $0 != "--dry-run" }
            if args == ["migrate"] { return .migrateVault(source: nil, dryRun: dryRun) }
            if args.count == 4, args[0] == "migrate", args[1] == "--source", args[3] == "--source-current", !args[2].hasPrefix("-") {
                return .migrateVault(source: args[2], dryRun: dryRun)
            }
            throw KeymanError.invalidRequest("用法：keyman vault status|unlock；keyman vault migrate [--source <原资料目录> --source-current] [--dry-run]。--source-current 表示已确认目录中的 Key 是现用版本。")
        case "catalog":
            guard !positional.contains(where: { $0.hasPrefix("-") }) else { throw KeymanError.invalidRequest("用法：keyman catalog [用途关键词] [--json]") }
            return .catalog(query: positional.isEmpty ? nil : positional.joined(separator: " "), json: json)
        case "guide", "example":
            guard positional.count == 2, !positional.contains(where: { $0.hasPrefix("-") }) else { throw KeymanError.invalidRequest("用法：keyman \(verb) <profile> <model> [--json]") }
            return verb == "guide" ? .guide(profile: positional[0], model: positional[1], json: json)
                : .example(profile: positional[0], model: positional[1])
        case "install-guides":
            guard positional.isEmpty || Array(positional) == ["--dry-run"] else { throw KeymanError.invalidRequest("用法：keyman install-guides [--dry-run]") }
            return .installGuides(dryRun: positional.contains("--dry-run"))
        case "list":
            return .list(json: json)
        case "profile":
            guard positional.count == 1 else {
                throw KeymanError.invalidRequest("用法：keyman profile <profile> [--json]")
            }
            return .profile(profile: positional[0], json: json)
        case "models":
            guard positional.count == 1 else {
                throw KeymanError.invalidRequest("用法：keyman models <profile> [--json]")
            }
            return .models(profile: positional[0], json: json)
        case "inspect":
            guard positional.count == 2 else {
                throw KeymanError.invalidRequest("用法：keyman inspect <profile> <model> [--json]")
            }
            return .inspect(profile: positional[0], model: positional[1], json: json)
        case "task":
            let values = Array(positional)
            guard [3, 5].contains(values.count), !values.prefix(3).contains(where: { $0.hasPrefix("-") }) else {
                throw KeymanError.invalidRequest("用法：keyman task <profile> <model> <任务编号> [--wait-seconds 0...600]")
            }
            var seconds = 0
            if values.count == 5 {
                guard values[3] == "--wait-seconds", let value = Int(values[4]), (0...600).contains(value) else {
                    throw KeymanError.invalidRequest("等待时间应为 0～600 秒；仅查询同一个任务，不创建新任务。")
                }
                seconds = value
            }
            return .task(profile: values[0], model: values[1], id: values[2], waitSeconds: seconds)
        case "call", "preflight":
            let allowWatermark = positional.contains("--allow-watermark")
            let values = Array(positional.filter { $0 != "--allow-watermark" })
            guard values.count >= 3,
                  !values[0].hasPrefix("-"), !values[1].hasPrefix("-") else {
                throw KeymanError.invalidRequest(
                    "用法：keyman call <profile> <model> (--body @file | --body-stdin)"
                )
            }
            if values.count == 4, values[2] == "--body",
               values[3].hasPrefix("@"), values[3].count > 1 {
                if verb == "preflight" || allowWatermark {
                    return .guardedCall(profile: values[0], model: values[1],
                        bodySource: .file(String(values[3].dropFirst())), allowWatermark: allowWatermark, preflight: verb == "preflight")
                }
                return .call(
                    profile: values[0],
                    model: values[1],
                    bodySource: .file(String(values[3].dropFirst())),
                    json: json
                )
            }
            if values.count == 3, values[2] == "--body-stdin" {
                if verb == "preflight" || allowWatermark {
                    return .guardedCall(profile: values[0], model: values[1],
                        bodySource: .standardInput, allowWatermark: allowWatermark, preflight: verb == "preflight")
                }
                return .call(
                    profile: values[0],
                    model: values[1],
                    bodySource: .standardInput,
                    json: json
                )
            }
            throw KeymanError.invalidRequest("请只提供一种请求体：--body @file 或 --body-stdin")
        case "run":
            guard let separator = arguments.firstIndex(of: "--"),
                  (separator == 2 || (separator == 3 && arguments[2] == "--allow-unchecked-output")),
                  separator + 1 < arguments.count else {
                throw KeymanError.invalidRequest("用法：keyman run <profile> [--allow-unchecked-output] -- <command>")
            }
            if separator == 3 { return .uncheckedRun(profile: arguments[1], command: Array(arguments[(separator + 1)...])) }
            return .run(
                profile: arguments[1],
                command: Array(arguments[(separator + 1)...])
            )
        case "verify":
            guard !positional.isEmpty, !positional.contains(where: { $0.hasPrefix("--") }) else {
                throw KeymanError.invalidRequest("用法：keyman verify <图片或视频文件> [更多文件]")
            }
            return .verify(paths: Array(positional))
        case "verify-response":
            let values = Array(positional)
            guard values.count == 4, values[2] == "--file" else {
                throw KeymanError.invalidRequest("用法：keyman verify-response <profile> <model> --file <已有响应.json>")
            }
            return .verifyResponse(profile: values[0], model: values[1], file: values[3])
        case "policy":
            if positional.isEmpty || Array(positional) == ["show"] { return .policy(nil) }
            let values = Array(positional)
            guard values.count == 2, values[0] == "set", let policy = OutputPolicy(rawValue: values[1]) else {
                throw KeymanError.invalidRequest("用法：keyman policy [show | set no-visible-watermark | set provider-default]")
            }
            return .policy(policy)
        case "watermark-config":
            let values = Array(positional)
            guard values.count == 4, values[2] == "--file" else {
                throw KeymanError.invalidRequest("用法：keyman watermark-config <profile> <model> --file <能力描述.json>")
            }
            return .configureWatermark(profile: values[0], model: values[1], file: values[3])
        case "import-preview":
            guard positional.count == 1 else {
                throw KeymanError.invalidRequest("用法：keyman import-preview <path> [--json]")
            }
            return .importPreview(path: positional[0], json: json)
        case "import-commit":
            guard positional.count == 1 else {
                throw KeymanError.invalidRequest("用法：keyman import-commit <path> [--json]")
            }
            return .importCommit(path: positional[0], json: json)
        case "import-check":
            guard positional.count == 1 else {
                throw KeymanError.invalidRequest("用法：keyman import-check <path> [--json]")
            }
            return .importCheck(path: positional[0], json: json)
        case "help", "--help", "-h":
            return .help
        default:
            throw KeymanError.invalidRequest("未知命令：\(verb)")
        }
    }
}
