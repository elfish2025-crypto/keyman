# Management commands

The GUI and CLI share management logic, configuration, and Keychain storage. Management documents contain no secrets. Commands return JSON, with exit code `0` for success and `1` for failure. Management writes support `--dry-run`, which validates the proposed change without modifying configuration, reading Keychain, or calling providers.

## Account groups

The account list is grouped by vendor, not by provider type. Each account may store an optional `group` (up to 40 characters, no line breaks); without one, Keyman infers it from the provider type and endpoint host (Volcengine, Alibaba Bailian, Vidu, Tencent Cloud, MiniMax), falling back to `其他`. Grouping and renaming never touch credentials, aliases, endpoints or models.

```bash
keyman profile update my-account --file group.json --dry-run   # {"group": "火山引擎", "name": "火山方舟 · 图像与视频"}
keyman list --json                                             # "group" is the effective group
```

## Balance page link

Each account can store an optional `balanceURL`: the provider's own balance or billing page. The GUI shows a balance button on every account row that opens the link in the default browser. Keyman never requests the page, sends credentials to it, or reads a balance.

```bash
keyman profile update my-account --file balance.json --dry-run   # {"balanceURL": "https://example.com/billing"}
keyman profile update my-account --file clear.json               # {"balanceURL": null}
keyman list --json                                               # "balanceURL" is the effective link
```

Only `https://` links without embedded credentials are accepted. When an account has no link, Keyman falls back to a built-in default matched on the endpoint host, limited to pages confirmed in official documentation: Alibaba Cloud billing (Bailian and `*.aliyuncs.com`), Tencent Cloud Expense Center (`*.tencentmaas.com`, `*.tencent.com`, `*.tencentcloudapi.com`) and MiniMax (`minimaxi.com`, `minimax.io`). Volcengine and Vidu have no confirmed default, so those accounts show a prompt to add a link. This field requires configuration schema 6; the first save by this version backs up the previous file.

## Move a model between accounts

```bash
keyman model move source-account model-alias destination-account --file model-patch.json --dry-run
keyman model move source-account model-alias destination-account --file model-patch.json
```

A move saves both account changes in one operation, preserves the model's internal ID, and neither reads nor transfers credentials. The destination account must already contain the endpoint referenced by the template. Name conflicts, invalid templates, and concurrent changes stop the operation without leaving the model partially moved.

Moving clears previous verification records. Explicitly resubmitting `usageGuide.requestExample` binds the reviewed example to the destination contract; otherwise, the old example requires review.

## Call workflow fields

The following optional `callTemplate` fields extend request handling. Omitted fields preserve the previous behavior.

| Field | Meaning |
|---|---|
| `responseFormat` | `json` (default), `volcengine-tts-sse`, `volcengine-voice-design`, `dashscope-tts-audio`, or `vidu-video` (added in 0.7.1) |
| `uuidHeaders` | Array of header names receiving a fresh UUID per request, such as `["X-Api-Request-Id"]`; cannot override authentication or static headers |
| `requiredBodyFields` | Array of dotted paths, such as `["req_params.text", "req_params.speaker"]`; empty or placeholder values stop the request before credential access |
| `taskQuery` | GET query contract for an asynchronous POST task; uses the same stored endpoint and credential |

Services that do not require a `model` parameter may set `modelID` and `modelIDBodyField` to `null`. For example, Doubao Speech V3 selects its service through resource headers rather than an Ark model ID. The SSE audio adapter supports mp3, ogg_opus, and pcm, and returns a local file after a complete response. It does not assess audio quality. Configure provider parameters from current official documentation.

`dashscope-tts-audio` is for Bailian non-streaming speech POST requests. The top-level model field must be `model`; `X-DashScope-SSE` cannot be configured at the same time. The response must have `output.finish_reason=stop` and a valid HTTP(S) `output.audio.url`. Empty results and intermediate audio fragments are not reported as success. This mode does not download the audio or assess how it sounds. Use a compatible app version before saving these fields; older applications must not manage newer configuration formats.

A Seedance task query contract belongs inside the model's `callTemplate`:

```json
{
  "taskQuery": {
    "path": "/contents/generations/tasks/{id}",
    "idPath": "id",
    "statusPath": "status",
    "pendingValues": ["queued", "running"],
    "successValues": ["succeeded"],
    "failureValues": ["failed", "cancelled"]
  }
}
```

Query an existing task with `keyman task account-alias model-alias TASK_ID --wait-seconds 60`. The path must be relative to the same endpoint and contain `{id}` exactly once. A query has no request body and does not create a generation task. After a timeout, continue querying the same task ID. Pending tasks or incomplete output inspection return exit code `3`; provider failure or cancellation returns `1`.

Since 0.7.1, `taskQuery.queryIDPath` can specify the ID field in query responses separately from submission responses. If omitted, it defaults to `idPath`, preserving older Seedance configurations. Vidu submissions return `task_id`, while queries return `id`, so both fields must be configured. `vidu-video` also enables Q3 parameter and provider-error checks. It takes output from `creations.*.url`, not `watermarked_url`, and requires this query contract:

```json
{
  "path": "/ent/v2/tasks/{id}/creations",
  "idPath": "task_id",
  "queryIDPath": "id",
  "statusPath": "state",
  "pendingValues": ["created", "queueing", "processing"],
  "successValues": ["success"],
  "failureValues": ["failed"]
}
```

Use Keyman 0.7.1 or later before saving `vidu-video` configuration, and restart any older MCP process. Review request fields, guides, and watermark evidence against the selected API. Preflight checks the model, duration, resolution, aspect ratio, prompt, image count, subject structure, and URL or encoding format. It does not download input images or verify pixel dimensions, remote accessibility, or provider permissions.

## Account, endpoint, model, and key operations

| Entity | Query | Create or update | Enable, disable, or delete |
|---|---|---|---|
| Account | `profile list`, `profile get ACCOUNT` | `profile add --file JSON`, `profile update ACCOUNT --file JSON` | `profile enable/disable/delete ACCOUNT` |
| Endpoint | `endpoint list ACCOUNT`, `endpoint get ACCOUNT ENDPOINT` | `endpoint add ACCOUNT --file JSON`, `endpoint update ACCOUNT ENDPOINT --file JSON` | `endpoint delete ACCOUNT ENDPOINT` |
| Model | `model list ACCOUNT`, `model get ACCOUNT MODEL` | `model add ACCOUNT --file JSON`, `model update ACCOUNT MODEL --file JSON` | `model enable/disable/delete ACCOUNT MODEL` |
| Key | `key status ACCOUNT` | `key set ACCOUNT --key-stdin` or `--key-file PRIVATE_FILE` | `key clear ACCOUNT` |

Uppercase names represent values you supply. Slashes indicate alternatives; for example, use `keyman profile disable example-account`. `profile add` can also accept `--key-stdin` or `--key-file` to save a credential. The CLI does not ask again before an authorized write; preview changes first, then execute as needed.

Accounts support `alias`, `name`, `provider`, `project`, `region`, `workspaceName`, `workspaceID`, `endpoints`, `authentication`, `notes`, `sourceFiles`, and `isEnabled`. Provider values are `volcengine-ark`, `alibaba-bailian`, and `custom-rest`. You can store an account and key before configuring its endpoints and authentication.

Endpoints support `alias`, `name`, and `baseURL`. HTTPS is required by default; HTTP is allowed only for local loopback testing. URLs cannot contain passwords, query parameters, or fragments. Renaming an endpoint updates its model references. An endpoint used by a model cannot be deleted. A standalone `endpoint update` rename preserves the endpoint's internal identity.

Models support `alias`, `name`, `modelID`, `modality`, `status`, `callTemplate`, `sourceFile`, `isEnabled`, and `usageGuide`. Modalities are `text`, `image`, `video`, `speech`, `voice-design`, and `other`. Writable statuses are `candidate`, `declared`, and `unavailable`; an existing `verified` state can be retained, but management operations cannot fabricate successful verification. Candidate and unavailable models cannot be called. Enabling one does not change its status.

`usageGuide` supports `summary`, `useCases`, `inputs`, `outputs`, `instructions`, `limitations`, `documentationURLs` (official HTTPS references), and `requestExample` (a JSON object without authentication data). Examples are replaced as a whole; `null` clears them. Do not put API keys, access tokens, Authorization headers, or other credentials into examples. See `examples/management-model-guide.json` for the structure.

Use `keyman catalog KEYWORD --json` to search, `keyman guide ACCOUNT MODEL --json` to read guides and missing requirements, and `keyman example ACCOUNT MODEL` to export a request body. These commands neither read Keychain nor call providers. `requestReady=true` means the local configuration is complete, not that credentials or remote access were verified. Changes to the model's API contract invalidate its example. Resubmitting `requestExample` declares that it has been reviewed against the current configuration; changing only the description does not reapprove it.

Call templates also support `endpointAlias`, `method`, `path`, `modelIDBodyField`, `staticHeaders`, `requestFields`, `isAsync`, and `outputPaths`. Paths are relative to the stored endpoint, such as `/chat/completions`. Static headers must not contain secrets. `requestFields` documents expected fields; the request must still satisfy the provider's contract. Callers query asynchronous tasks separately. Watermark capabilities are managed through `watermark-config`; see the README for output policy boundaries.

Example partial update:

```json
{"name":"New display name","project":null,"isEnabled":false}
```

Omitted fields retain their current values. `null` clears optional fields. Arrays are replaced in full. `staticHeaders` is also replaced in full, with `{}` clearing additional headers. Account management documents reject unknown fields, internal IDs, full keys, model collections, and verification records.

Changing only account or endpoint display names and aliases preserves existing capability evidence. Changing a model version, endpoint URL, path, authentication, or another part of the actual API contract invalidates previous verification and watermark capabilities; visual models must be reviewed again. Replacing or clearing a key clears previous call-verification records.

Saves check for concurrent configuration changes, so stale edits cannot overwrite newer account settings. Credential changes and imports use a separate interprocess lock; waiting for Keychain authorization does not block ordinary metadata editing. If metadata changes during that wait, the credential operation stops or rolls back and asks for a retry. If Keychain errors prevent rollback, the operation reports the failure rather than claiming success.

`profile test ACCOUNT` is a separate access check. For Bailian it sends a read-only `/models` authentication request; for other providers it checks the local credential. This does not establish a successful model call. `preflight` validates a request locally, while `call` sends a real request that may incur charges. Report these outcomes separately.

Users choose the legacy import source directory; see [legacy import](import.md) for its format. `import-check` matches current and historical account aliases against Keychain. Matching keys preserve user configuration; different keys stop the operation. A renamed account retains its former aliases so re-importing does not create duplicates.
