# Release validation

Date: 2026-11-15.

The public repository contains selected source code, tests, generic examples, and documentation. It does not inherit the private development repository's Git history or include real account configuration, credentials, provider call receipts, or internal creative materials.

## 0.7.4: local checks

- **Swift 6.3 / macOS arm64:** the full run covered 160 tests. Seven Vidu test functions, comprising 29 parameterized cases, initially failed because their resource directory had not yet been copied; the other tests passed. After adding synthetic fixtures loaded through the resource bundle, all 15 targeted Vidu, task-query, and affected Bailian import tests passed. The initial run was not recorded as an all-pass run.
- **Python installer tests:** all 7 passed.
- **Release build, ad-hoc signature verification, and ZIP content verification:** passed. The build was not installed over the active application.
- **Gitleaks 8.30.1:** no secrets detected in the reviewed public files. A specific workspace ID in test data was replaced with a synthetic value. This scan is not a guarantee that the software has no vulnerabilities.
- **Local documentation links:** passed.

Automated tests used synthetic credentials and mocked transports. No provider generation requests were submitted. The folder picker compiled but was not manually exercised. System Keychain authorization and real credential replacement were not performed during this release validation.

## 0.7.5: Xcode compatibility fix

The first GitHub CI run found a Swift concurrency compilation error in the UI test helper: its asynchronous closure lacked explicit actor isolation, allowing a generic return value to cross an isolation boundary. The closure was marked `@MainActor`, matching its UI test context, without an unsafe concurrency exemption. All 16 affected App tests passed locally; unaffected checks were reused.

[GitHub CI for commit `8657ec3`](https://github.com/elfish2025-crypto/keyman/actions/runs/43717745640) then passed the complete 160-test Swift suite, all 7 installer tests, and application packaging with signature and archive verification in a fresh macOS environment.

## 0.7.6: English documentation

This update changes Markdown documentation only. The application, CLI messages, MCP implementation, examples, and fixtures remain unchanged. Validation checks local links, JSON code blocks, command examples, and the changed-file list. Runtime test results from 0.7.5 remain applicable; translating documentation does not imply new live provider or UI verification.
