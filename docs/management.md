# Keyman 管理命令

GUI 与 CLI 共用管理逻辑、配置文件和钥匙串。管理文档不包含密钥；变更命令返回 JSON，成功为退出码 0，失败为 1。写操作均支持 `--dry-run`，仅校验计划，不改配置、不读取钥匙串、不调用供应商。

## 模型跨账号迁移

```bash
keyman model move <原账号> <模型> <目标账号> --file <迁移时更新的模型字段.json> --dry-run
keyman model move <原账号> <模型> <目标账号> --file <迁移时更新的模型字段.json>
```

迁移一次保存两个账号的变化，保留模型内部 ID，不读取或转移凭证。目标账号须已配置模板引用的接口。名称冲突、无效模板或并发变更时停止，不留下只迁出未迁入的状态。迁移清除旧验证记录；若明确重交 `usageGuide.requestExample`，则绑定目标接口，否则旧示例会等待重新核对。

## 调用流程字段

`callTemplate` 增加以下可选字段，旧配置缺省保持原行为：

| 字段 | 值与作用 |
|---|---|
| `responseFormat` | `json`（默认）、`volcengine-tts-sse`、`volcengine-voice-design`、`dashscope-tts-audio`；0.7.1 新增 `vidu-video` |
| `uuidHeaders` | 字符串数组；每次请求自动生成新的 UUID，例如 `["X-Api-Request-Id"]`；不能覆盖认证或静态头 |
| `requiredBodyFields` | 点分路径数组，例如 `["req_params.text", "req_params.speaker"]`；空值/占位符在读取 Key 前停止 |
| `taskQuery` | 异步 POST 的后续 GET 查询契约；与创建请求使用同一已保存接口和凭证 |

真正无需 `model` 参数的服务，可将 `modelID` 和 `modelIDBodyField` 设为 `null`。例如豆包语音 V3 由资源头选择服务，不使用方舟 Model ID。SSE 音频支持 mp3、ogg_opus、pcm；完整结束后返回本机文件，未验证内容质量。供应商参数须按当前官方文档配置。

`dashscope-tts-audio` 仅用于百炼非流式语音 POST，顶层模型字段为 `model`，不能同时配置 `X-DashScope-SSE`。要求响应 `output.finish_reason=stop`，且 `output.audio.url` 为有效的 HTTP(S) 地址；空结果或中间音频片段不报告成功。此模式不下载音频或判断听感。升级应用后才能保存这种格式，不能将 0.6.1 配置写给旧版程序。

Seedance 的任务查询契约如下（放入模型的 `callTemplate`）：

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

使用 `keyman task <账号> <模型> <任务编号> [--wait-seconds 60]` 查询已有任务。路径必须是同一接口下的相对路径，包含一次 `{id}`。查询没有请求体，不提交新生成；超时保留同一个任务编号继续查。状态等待或成品检查未完成退出码 3，供应商失败/取消退出码 1。

0.7.1 的 `taskQuery.queryIDPath` 可单独指定查询响应里的任务编号字段；省略时沿用 `idPath`，旧 Seedance 配置无需变更。Vidu 创建返回 `task_id`，查询返回 `id`，必须分别填写。`vidu-video` 同时启用 Q3 参数检查及响应错误检查，模板固定取 `creations.*.url`，不取 `watermarked_url`。它要求以下查询契约：

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

先安装 0.7.1，再保存 `vidu-video` 配置；同时重启仍在运行的旧 MCP 服务。请求、指南及水印依据应按所用接口核对。预检校验型号、时长、分辨率、画幅、提示词、图片数量、主体结构及 URL/编码形式；不下载输入图片，不验证像素尺寸、远程可访问性或供应商权限。

## 原有管理操作

| 对象 | 查询 | 创建／修改 | 启停／删除 |
|---|---|---|---|
| 账号 | `profile list`、`profile get <账号>` | `profile add --file <JSON>`、`profile update <账号> --file <JSON>` | `profile enable/disable/delete <账号>` |
| 接口 | `endpoint list <账号>`、`endpoint get <账号> <接口>` | `endpoint add <账号> --file <JSON>`、`endpoint update <账号> <接口> --file <JSON>` | `endpoint delete <账号> <接口>` |
| 模型 | `model list <账号>`、`model get <账号> <模型>` | `model add <账号> --file <JSON>`、`model update <账号> <模型> --file <JSON>` | `model enable/disable/delete <账号> <模型>` |
| Key | `key status <账号>` | `key set <账号> --key-stdin` 或 `--key-file <私有文本文件>` | `key clear <账号>` |

表中的 `/` 表示选择一个命令，例如 `keyman profile disable example-account`。`profile add` 也可附带 `--key-stdin` 或 `--key-file` 创建凭证。CLI 不再重复确认已授权的写操作；先预览，再按需要执行。

账号支持 `alias`、`name`、`provider`、`project`、`region`、`workspaceName`、`workspaceID`、`endpoints`、`authentication`、`notes`、`sourceFiles`、`isEnabled`。供应商值为 `volcengine-ark`、`alibaba-bailian`、`custom-rest`。可以先只存账号与 Key，稍后补齐接口和认证。

接口支持 `alias`、`name`、`baseURL`。HTTPS 为默认要求；HTTP 仅允许本机回环测试。URL 不含密码、查询参数或片段。更改接口标识会同时更改模型引用；被模型引用的接口不能删除。通过独立的 `endpoint update` 改接口名，可保留其内部身份。

模型支持 `alias`、`name`、`modelID`、`modality`、`status`、`callTemplate`、`sourceFile`、`isEnabled`、`usageGuide`。模态为 `text`、`image`、`video`、`speech`、`voice-design`、`other`。状态为 `candidate`、`declared`、`unavailable`；已有 `verified` 可以保留，管理操作不能手动伪造验证成功。候选与不可用模型不能调用，即使启用也不会自动改变状态。

`usageGuide` 支持 `summary`（用途）、`useCases`（任务数组）、`inputs`、`outputs`、`instructions`（步骤数组）、`limitations`（限制数组）、`documentationURLs`（HTTPS 官方资料数组）、`requestExample`（不含认证信息的 JSON 对象）。示例整体替换，`null` 清空；Key、Access Token、Authorization 等认证字段不得写入示例。完整示例见 `examples/management-model-guide.json`。

`keyman catalog <用途关键词> --json` 检索，`keyman guide <账号> <模型> --json` 读取指南和缺项，`keyman example <账号> <模型>` 导出请求体。这些命令不读取钥匙串或调用供应商。`requestReady=true` 仅指本机资料齐备，凭证和远程服务仍未由该查询验证。模型配置变更会使原示例过期；在更新文件中重新提交 `requestExample` 表示已核对当前配置，仅修改介绍不会重新批准旧示例。

调用模板支持 `endpointAlias`、`method`、`path`、`modelIDBodyField`、`staticHeaders`、`requestFields`、`isAsync`、`outputPaths`。路径相对已保存的接口，例如 `/chat/completions`；静态请求头只放非密钥信息。`requestFields` 记录字段提示，具体请求仍须符合供应商契约。异步接口后续轮询由调用方执行。水印能力使用独立的 `watermark-config` 命令，详见 README。

局部修改示例：

```json
{"name":"新名称","project":null,"isEnabled":false}
```

省略字段保持原值，`null` 清除可选字段；数组替换整个数组。`staticHeaders` 整体替换，`{}` 清除附加头。未知字段、内部 ID、完整 Key、模型集合及验证记录不能写入账号管理文档。

账号与接口只改显示名称、标识时保留现有模型能力依据。修改模型版本、接口地址、路径、认证等实际调用契约后，旧的验证记录和水印能力失效，视觉模型须重新核对。更换或清除 Key 会清除旧的调用验证记录。

保存使用配置冲突检查；相同账号的旧编辑不会覆盖新配置。Key 修改与导入使用独立的进程间锁，等待钥匙串授权时不会锁住普通元数据编辑。元数据在此期间发生变化，凭证操作会停止或恢复后提示重试。若恢复本身受钥匙串错误阻碍，会明确报错，不宣称保存成功。

`profile test <账号>` 是独立的检查：百炼发起只读 `/models` 鉴权，其他供应商检查本机凭证。它不代表真实模型已完成调用。`preflight` 只校验请求，`call` 会发送真实请求并可能计费；这三种结果应分别记录。

原始导入目录由用户选择，格式见 [导入说明](import.md)。`import-check` 按当前和历史账号标识核对钥匙串。Key 相同则不覆盖用户配置；Key 不同则停止。账号改名后，旧标识仍为其保留，避免重新导入生成重复账号。
