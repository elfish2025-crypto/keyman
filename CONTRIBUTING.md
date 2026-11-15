# Contributing

Issues and pull requests are welcome. Describe the trigger, expected behavior, and actual result. Redact logs before sharing them.

1. Use macOS 14+, Swift 6+, and Python 3.10+.
2. Create a branch from `main` and keep changes focused.
3. Run `./scripts/test.sh` and `python3 -m unittest discover -s Tests/Installation`. For packaging changes, also run `./scripts/package-app.sh`.
4. Explain the reason for the change, validation results, and known limitations in your PR. For UI changes, include screenshots using synthetic data.

Do not commit personal configuration, call receipts, signed media URLs, real account resource IDs, or secrets. Tests should use temporary directories, synthetic credentials, and mocked transports. Routine tests must not use a developer's real Keychain or submit paid generation requests.

Provider adapters should cite official API documentation and distinguish parameter validation from successful live calls. Do not treat access granted to one local account as a general product capability.

Changes to configuration, credentials, and task state must preserve concurrency checks and failure recovery. Adding a feature must not silently make metadata queries read credentials or call providers.

By contributing, you agree to license your contributions under this project's MIT license.
