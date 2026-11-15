# Changelog

## 0.7.6 — 2026-11-15

Documentation-only repository update. The application and MCP server remain at version 0.7.5.

- Translate the README, usage guides, security policy, contribution guide, changelog, and release validation record into English.
- Preserve command syntax, configuration fields, links, and the Chinese filenames and field names required by the legacy importer.
- Clarify that the application interface and CLI messages are still in Chinese.
- No changes to application behavior, credentials, configuration schema, or test fixtures.

## 0.7.5 — 2026-11-15

- Explicitly isolate the UI asynchronous test helper to the main actor, fixing a Swift concurrency compilation error in the GitHub macOS/Xcode environment.
- Synchronize application and MCP versions at 0.7.5; runtime behavior and configuration formats are unchanged.
- Preserve the initial public snapshot tag `v0.7.4` without rewriting published history.

## 0.7.4 — 2026-11-15

Initial public source snapshot, starting a separate public history from the local 0.7.3 working tree.

- Include the macOS GUI, CLI, 30 stdio MCP tools, and core tests.
- Replace the hard-coded import directory with a folder picker, and stop prefilling the developer's migration path.
- Use generic account names and synthetic test data.
- Synchronize application and MCP version metadata; support both full Xcode and standalone Command Line Tools in the test entry point.
- Add the MIT license, installation and configuration guides, contribution guidelines, security boundaries, and macOS CI.
- Exclude the developer's accounts, model catalog, call records, internal documents, and original Git history.

Compatibility: the configuration schema and CLI/MCP interfaces retain their previous implementation. Legacy imports use generic fallback names when names are absent. The project is pre-1.0 and does not yet promise a stable public API.

Installation is from source. No Developer ID signature or Apple notarization is provided. Automated tests do not replace live provider calls or output quality review.
