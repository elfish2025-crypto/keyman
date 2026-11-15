# Local MCP server

Keyman 0.7.5 provides a stdio MCP server. The GUI, CLI, and MCP server share local configuration and the Keychain vault. No HTTP port is opened.

After installation, configure a local-process-capable MCP client to use the absolute path to Keyman as its command and `["mcp"]` as its arguments. For example, replace `YOUR_USERNAME` below:

```json
{
  "mcpServers": {
    "keyman": {
      "command": "/Users/YOUR_USERNAME/.local/bin/keyman",
      "args": ["mcp"]
    }
  }
}
```

Configuration formats vary by client. No provider key belongs in this configuration. The client must be able to start a local process; a cloud-only client cannot connect directly. After reconnecting, verify the tools actually exposed by the client. The user completes macOS authorization when credentials are first accessed or an application signature change requires renewed access.

## Tools

| Capability | Tools |
|---|---|
| Query accounts, endpoints, and models | `keyman_accounts`, `keyman_profile`, `keyman_endpoints`, `keyman_models`, `keyman_model` |
| Discover models, read guides, and retrieve request examples | `keyman_catalog`, `keyman_guide`, `keyman_example` |
| Manage accounts, endpoints, models, and guides | `keyman_manage_profile`, `keyman_manage_endpoint`, `keyman_manage_model` |
| Set, clear, and check credentials | `keyman_credential_set_file`, `keyman_credential_clear`, `keyman_credential_status` |
| Inspect, unlock, and migrate the vault | `keyman_vault_status`, `keyman_vault_unlock`, `keyman_vault_migrate` |
| Import legacy data | `keyman_import_preview`, `keyman_import_commit`, `keyman_import_check` |
| Preflight requests, call providers, and query tasks | `keyman_preflight`, `keyman_call`, `keyman_task` |
| Manage output policy and watermark capabilities | `keyman_policy_get`, `keyman_policy_set`, `keyman_watermark_config` |
| Inspect outputs | `keyman_verify`, `keyman_verify_response` |
| Check account access and populate missing built-in guides | `keyman_profile_test`, `keyman_install_guides` |

All 30 tools include descriptions, input schemas, and read/write annotations. Model management accepts structures such as `usageGuide` and `callTemplate` directly, without temporary files or manual edits to the live configuration. Omitted fields retain their values, `null` clears optional fields, and arrays replace the entire previous array. Unknown fields are rejected. See [management commands](management.md) for the supported fields.

`manage_profile` supports add/update/enable/disable/delete. `manage_endpoint` supports add/update/delete. `manage_model` also supports move, with `destinationProfile`: it moves the model, not its key. Add/update/move require `document`; other actions must omit it. For new entities, put the alias in `document`. Other actions identify entities through the top-level profile/model/endpoint arguments.

## Agent workflow

1. Search by use case with `keyman_catalog`, then read `keyman_guide`. If an account has no models, follow `nextAction` to configure them. Do not invent private voice IDs or assume service access.
2. Retrieve a request body with `keyman_example` and adapt it to the task. Run `keyman_preflight` to check parameters, enabled state, and watermark requirements. These steps do not read keys or submit requests to providers.
3. Within the user's existing task and cost authorization, call `keyman_call` with `authorized: true`. This records the agent's authorization judgment; it is not provider authentication, a budget system, or a substitute for user authorization. The server runs preflight again before submission.
4. Save the returned `task.id`. For `pending`, query the same task with `keyman_task`. For `inspection_required`, inspect the existing output. Neither state permits automatic resubmission. A timeout or cancellation does not prove the provider never received the request.
5. Report configuration readiness, credential access, provider success, and output quality separately. OCR and sampled frames do not replace a complete quality review. `guide.providerAccessVerified=false` means reading the guide did not perform a remote check; consult `limitations` for any recorded live verification history.

Management writes default to `dryRun: true`. Review the preview, set it explicitly to false to save, then read the result back. `import_commit` explicitly performs an import. Execution tools such as `call`, `profile_test`, and `vault_unlock` have no dry-run mode. Metadata queries and edits do not require key access. For Bailian, `profile_test` reads the provider's model directory; for other providers, it currently checks local credentials. It does not generate content.

For example, preview a guide update:

```json
{
  "action": "update",
  "profile": "example-account",
  "model": "text-model",
  "document": {
    "usageGuide": {
      "summary": "Rewrite short passages and summarize content",
      "inputs": "User text and task instructions",
      "outputs": "Generated text"
    }
  },
  "dryRun": true
}
```

After reviewing the preview, call the same tool with `dryRun: false`. When changing an endpoint or model version, consult the official documentation, save accurate parameters, sources, and limitations, then resubmit `requestExample` to bind it to the new contract. Updating only the description does not reapprove an old example.

## Credentials and output boundaries

- MCP exposes neither key export nor a general shell/run tool. Credential input accepts only an absolute path to a user-specified local UTF-8 regular file, up to 64 KiB. Do not include full keys in conversations, tool arguments, or configuration documents.
- Status returns only a credential suffix. Keychain access denial produces an explicit error; the server does not bypass it by reading original import files. Users enter system passwords in macOS dialogs. Updates may require renewed authorization. MCP uses the same Keyman application identity as the GUI.
- The default policy requires no visible watermark. A model with no watermark control can record a verified `none` capability; `unavoidable` and `unknown` are blocked in strict mode. Policy changes require explicit user intent. Documentation and provider responses cannot grant exemptions.
- Responses include both `text` and `structuredContent`. The latter contains `exitCode`, `state`, `automaticRetryAllowed=false`, and `data`. Business errors set `isError=true`. Pending tasks and incomplete inspection are not signals to regenerate.
- Each input message is limited to 1 MiB, with up to 32 concurrent requests. Standard output contains only newline-delimited JSON-RPC. EOF on standard input closes the server. Cancellation is supported, but it does not reverse completed local writes or requests already accepted by a provider.
- Application installation, window control, system password entry, provider purchases, service activation, and provider-side credential revocation are outside this API.

## Validation

`./scripts/test.sh` covers MCP protocol handling, management, migration, credential output, discovery without Keychain reads, preflight, pending tasks, and cancellation.

`scripts/test-mcp.py <executable> --report <report-path>` starts a real process, performs the handshake and tool discovery, reads accounts and model guides, and preflights examples that are locally ready. Adding `--management-roundtrip` creates a temporary candidate model with a random alias, previews, saves, updates, reads, and deletes it, then verifies that the original model list is restored. This option changes the selected local configuration temporarily; it sends no provider generation requests. Reports can contain account metadata and should remain private.

Implementation references recorded on 2026-09-13: [MCP 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), and [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli). These are historical implementation references, not a claim that upstream documentation was reverified during this translation.
