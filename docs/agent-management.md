# Agent capabilities

This document describes the management interfaces in Keyman 0.7.5. For request configuration, see [management commands](management.md).

## Connection options

- **Local CLI:** `~/.local/bin/keyman`. Management commands return JSON.
- **HTTP management API:** not provided. There is no listening management server.
- **MCP:** 30 local stdio tools for compatible clients. See [MCP setup](mcp.md).
- The GUI, CLI, and MCP server share management and validation logic. Agents do not need to click through the interface to manage accounts and models.

An agent must be able to execute local commands or start the MCP process on the Mac. A client limited to remote network APIs cannot directly access this local stdio server.

## Operations

| Operation | Agent entry point | Behavior |
|---|---|---|
| Query accounts, projects, regions, workspaces, and authentication | `list`, `profile get` | Returns configuration, not full keys |
| Add, update, rename, enable, disable, or delete accounts | `profile add/update/enable/disable/delete` | Deletion removes local credentials but does not revoke provider-side keys |
| Set, replace, inspect, or clear a key | `key set/status/clear` | Accepts standard input or a private file; status shows only a suffix |
| Add, edit, or delete endpoints | `endpoint add/update/delete` | Endpoints referenced by models cannot be deleted |
| Add, edit, enable, disable, or delete models | `model add/update/enable/disable/delete` | Manages IDs, templates, and output fields; cannot fabricate successful verification |
| Move a model to another account | `model move` | Updates both accounts atomically, preserves the model ID, and does not read or move credentials |
| Edit use cases, inputs, outputs, instructions, limitations, and examples | `model update` with `usageGuide` | Examples must be reviewed again when the API contract changes |
| Search models, read guides, and export examples | `catalog`, `guide`, `example` | Does not read Keychain or call providers |
| Populate built-in guides | `install-guides` | Fills missing guides without replacing user-maintained ones |
| Preview, commit, or verify an import | `import-preview/commit/check` | Stops on a different key rather than overwriting it |
| Check, unlock, or migrate the credential vault | `vault status/unlock/migrate` | System authorization dialogs still require user input |
| Change the default output policy | `policy show/set` | Shares the global policy with the GUI |
| Record model watermark capabilities | `watermark-config` | Evidence is bound to the model version and API contract |
| Check account access | `profile test` | Separate from successful model invocation |
| Validate or execute requests | `preflight`, `call` | Preflight does not contact the provider; calls require task authorization |
| Query or wait for a generation task | `task` | Queries a fixed task ID without regenerating; inspects completed output |
| Inspect existing images, videos, or responses | `verify`, `verify-response` | Does not equate HTTP success with acceptable output |
| Read changes made by another window or client | Repeat a query | Queries load the current configuration |

Slashes in command names indicate alternatives, not literal command syntax. GUI business operations have corresponding command entry points; some require several commands. Opening windows, navigation, and system password entry are not management commands.

## Application maintenance

Packaging, installation, and archiving old app copies use repository scripts: `package-app.sh`, `install-local.sh`, and `app_installation.py cleanup`. They are not part of the installed `keyman` management API and are not exposed over HTTP or MCP.

Creating or revoking keys at a provider, purchasing credits, and activating models are outside Keyman's management scope. Removing a local key does not revoke its provider-side counterpart.

## Validation scope

Automated tests use synthetic credentials, temporary directories, and mocked transports. Live provider calls, account authorization, and output quality must be verified separately in each deployment environment.
