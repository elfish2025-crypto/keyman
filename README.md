# Keyman

**Manage API credentials, accounts, endpoints, and models for local AI agents.**

Keyman is a macOS app with a CLI and 30 stdio MCP tools. Store API keys locally and let agents call services through configured accounts and models. Routine queries and model guides do not return full credentials.

Credentials are stored in macOS Keychain. The project is licensed under MIT.

## Features

- Manage multiple providers, accounts, authentication methods, endpoints, and models in one app.
- Maintain model guides with use cases, inputs, outputs, official references, request examples, and asynchronous task query rules.
- Let agents discover models, read guides, preflight requests, and make authorized calls.
- Store, replace, clear, and migrate credentials through macOS Keychain.
- Check images and videos for common visible text watermarks under the default output policy. Keep pending inspection states separate from failed requests to avoid duplicate generation.

Keyman supports configurable REST endpoints and selected workflows for Volcengine Ark, Alibaba Cloud Model Studio (Bailian), Volcengine Speech, and Vidu. Support depends on the specific API contract. Providers control account permissions, billing, and model availability. This repository includes no real accounts, API keys, or paid service credits.

## Build and install

Requires **macOS 14+, Swift 6+, and Python 3.10+**, with compatible Apple Command Line Tools or Xcode. The app interface and CLI messages are currently in Chinese. Keyman is a pre-1.0 project.

```bash
git clone https://github.com/elfish2025-crypto/keyman.git
cd keyman
./scripts/test.sh
python3 -m unittest discover -s Tests/Installation
./scripts/package-app.sh
./scripts/install-local.sh
open "$HOME/Applications/Keyman.app"
```

Packaging produces `dist/Keyman.app.zip`. The installer places the app in `~/Applications` and creates the `~/.local/bin/keyman` symlink. If Keyman is already installed, quit the app and any MCP processes using it first. The installer archives the replaced version. Account configuration and credentials are not included in the package.

Builds use local ad-hoc signing; no Apple Developer ID signature or notarization is provided. Build from source to install this release. macOS may ask for Keychain authorization again after a rebuild.

The commands below assume `~/.local/bin` is on your PATH. Otherwise, use `"$HOME/.local/bin/keyman"`.

## Getting started

Open the app and choose **Add account** (currently labeled `添加账号`). Select a provider or custom REST endpoint, then enter your endpoint and authentication settings. You can add the API key later. Add a model and its usage guide next. Accounts, endpoints, and models can also be managed through the CLI or MCP.

The repository examples use `example.invalid` and candidate models to illustrate configuration structure. They cannot call a real service as supplied:

```bash
keyman profile add --file examples/management-profile.json --dry-run
keyman profile add --file examples/management-profile.json
keyman endpoint add example-account --file examples/management-endpoint.json
keyman model add example-account --file examples/management-model.json
keyman model update example-account text-model --file examples/management-model-guide.json
keyman guide example-account text-model --json
```

Before making a call, configure the actual endpoint, authentication, model ID, and request example using the provider's official documentation. Changes to the API contract invalidate old examples. Resubmitting `usageGuide.requestExample` declares that the example has been reviewed against the current configuration.

Store full keys through the app's secure input field, a private local file, or standard input. Do not put them in command-line arguments, model examples, Git repositories, or chat messages:

```bash
keyman key set example-account --key-file /absolute/private/path/key.txt
keyman key status example-account
```

## Agent workflow

```bash
keyman catalog speech --json
keyman guide my-account my-model --json
keyman example my-account my-model > request.json
# Edit request.json for the current task.
keyman preflight my-account my-model --body @request.json
# Run only with authorization for the task and its costs:
keyman call my-account my-model --body @request.json
```

`catalog`, `guide`, `example`, and `preflight` do not call the provider. `requestReady` means the local configuration is complete; it does not verify credentials, service access, or output quality. `call` sends a real request and may incur charges.

For asynchronous requests, save the task ID and query the same task with `keyman task my-account my-model TASK_ID --wait-seconds 60`. Exit code `3` means the task is pending or output inspection is incomplete. It is not a signal to generate again. A network timeout also does not prove that the provider rejected or never received the request.

### Agent skill

`skills/keyman/SKILL.md` is a Claude Code skill that teaches an agent this workflow (list → catalog → guide → example → preflight → ask → call → task). It triggers on phrases such as "用 Keyman 查一下" or "用某服务商的某模型做某事，去 Keyman 拿密钥". To install it for your user account:

```bash
mkdir -p ~/.claude/skills && ln -s "$PWD/skills/keyman" ~/.claude/skills/keyman
```

See [MCP setup and tools](docs/mcp.md), [management commands](docs/management.md), [agent capabilities](docs/agent-management.md), and [legacy import](docs/import.md).

## Credentials and output checks

Credentials are stored in the unified macOS Keychain item `com.local.keyman.vault / credentials-v1`. Account and model configuration lives at `~/Library/Application Support/Keyman/config.json`; call and inspection records are stored in its `Calls/` directory. Treat these as private data and keep them out of Git.

Users must complete system authorization in the macOS dialog. Clearing a local key does not revoke it at the provider. Do not use an older app version to modify a newer configuration. See [SECURITY.md](SECURITY.md) for the security boundaries and reporting process.

The default policy requires no visible watermark. Unknown or unavoidable watermark behavior blocks the request before submission. Capability claims must be supported by evidence for the specific model and endpoint. Image checks use Vision OCR. Video checks inspect the first and last frames and sample roughly every two seconds, with limits of 180 seconds and 200 MiB per file. They may miss graphical marks, brief watermarks, or blurred text, and do not detect invisible watermarks. Passing automated inspection does not establish visual, audio, or content quality.

The CLI's `run` compatibility mode passes credentials to the child process through environment variables, so use it only with trusted programs. Under the strict output policy, it requires an explicit `--allow-unchecked-output` override. MCP exposes neither a general shell nor a key export tool.

## Development

`Sources/KeymanCore` implements configuration, credentials, requests, and management logic. `KeymanCLI` provides the CLI and MCP server. `KeymanAppSupport` and `KeymanApp` provide the SwiftUI interface and application entry point.

There are no third-party Swift Package dependencies. Tests use synthetic credentials and mocked services; never add real keys to fixtures. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [changelog](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 elfish2025-crypto. This project is not affiliated with the API providers.
