# 本机 MCP

Keyman 0.7.5 提供 stdio MCP。GUI、CLI 和 MCP 共用本机配置与钥匙串凭证库，不监听 HTTP 端口。

安装后在支持启动本机进程的 MCP 客户端中，将 command 设为 Keyman 的绝对路径，args 设为 `["mcp"]`。例如（替换 YOUR_USERNAME）：

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

各客户端配置结构可能不同。连接无需填写供应商 Key；需要本机工具执行能力，不能从纯云端客户端直接访问。重新连接后以客户端实际工具列表为准。首次读取凭证或应用签名变化时，由用户在 macOS 系统窗口授权。

## 30 个工具

| 能力 | 工具 |
|---|---|
| 账号、接口和模型查询 | `keyman_accounts`、`keyman_profile`、`keyman_endpoints`、`keyman_models`、`keyman_model` |
| 按用途找模型、读说明、取得请求体 | `keyman_catalog`、`keyman_guide`、`keyman_example` |
| 管理账号、接口、模型及用途资料 | `keyman_manage_profile`、`keyman_manage_endpoint`、`keyman_manage_model` |
| 凭证配置、清除及状态 | `keyman_credential_set_file`、`keyman_credential_clear`、`keyman_credential_status` |
| 统一凭证库状态、解锁和迁移 | `keyman_vault_status`、`keyman_vault_unlock`、`keyman_vault_migrate` |
| 资料导入 | `keyman_import_preview`、`keyman_import_commit`、`keyman_import_check` |
| 请求预检、真实调用和任务查询 | `keyman_preflight`、`keyman_call`、`keyman_task` |
| 水印策略和模型能力维护 | `keyman_policy_get`、`keyman_policy_set`、`keyman_watermark_config` |
| 成品检查 | `keyman_verify`、`keyman_verify_response` |
| 账号检测和内置说明补全 | `keyman_profile_test`、`keyman_install_guides` |

工具具有用途说明、完整输入结构和读写标注。管理模型时可直接传 `usageGuide`、`callTemplate` 等结构，不需要 Agent 临时生成文件或手工编辑运行中的配置。省略字段保留原值，`null` 清空可选字段，数组整体替换；工具会拒绝未知字段。管理字段详见 [管理文档](management.md)。

`manage_profile` 支持 add/update/enable/disable/delete；`manage_endpoint` 支持 add/update/delete；`manage_model` 另外支持 move，需指定 `destinationProfile`，只移动模型，不移动 Key。add/update/move 必须传 `document`，其他动作不得传。新增实体的 alias 放在 `document` 中，其余动作使用顶层 profile/model/endpoint 定位。

## Agent 工作流程

1. `keyman_catalog` 按用途搜索，再读 `keyman_guide`。账号没有模型时按 nextAction 补配置；私有音色或未开通的权限不能猜。
2. 用 `keyman_example` 取得请求体，再填写任务内容；`keyman_preflight` 检查参数、停用状态和水印。此阶段不读 Key、不向供应商提交。
3. 在用户已有任务及费用授权范围内，调用 `keyman_call`，明确传 `authorized: true`。该参数记录 Agent 的授权判断，不是新的供应商鉴权或预算计费系统，不能自行填 true 绕过用户授权。服务还会再执行一次本机 preflight。
4. 保存返回的 task.id。`pending` 表示继续用 `keyman_task` 查询同一个任务；`inspection_required` 表示处理已有成品检查。二者均不得自动重新生成。超时或取消也不能证明供应商未收到请求。
5. 本次资料齐备、凭证可读、供应商请求成功和成品质量合格分别说明。自动 OCR/抽帧不等于完整人工质量验收。`guide.providerAccessVerified=false` 仅表示读取指南没有发起远程验证，已有实测记录应查看 limitations。

管理写操作默认 `dryRun: true`（只预览），审阅后明确传 false 保存，再回读。`import_commit` 的名称已明确表示保存；`call`、`profile_test`、`vault_unlock` 则是执行型工具，没有 dryRun。元数据查询和修改不要求读取 Key。`profile_test` 在百炼会访问只读模型目录，其他供应商目前检查本机凭证，均不生成内容。

例如更新模型介绍：

```json
{
  "action": "update",
  "profile": "example-account",
  "model": "text-model",
  "document": {
    "usageGuide": {
      "summary": "适合短文改写与内容归纳",
      "inputs": "用户文本与任务说明",
      "outputs": "生成的文本"
    }
  },
  "dryRun": true
}
```

预览后调用同一工具，将 dryRun 改为 false。更换接口或模型版本时，请重新查官方文档，保存准确参数、来源及限制，再提交 `requestExample` 重新绑定契约。只修改介绍不会批准旧示例。

## 凭证与输出边界

- MCP 不提供 Key 导出和通用 shell/run。凭证设置仅接受用户指定的本机 UTF-8 普通文件绝对路径（最多 64 KiB）；不能把完整 Key 放进对话、工具参数或配置。
- 状态只返回末四位；钥匙串拒绝访问时返回明确错误，不从原资料目录绕过读取。系统密码仍由用户在 macOS 窗口输入。应用更新可能需要重新授权签名，MCP 沿用与 GUI 相同的 Keyman 身份。
- 默认无可见水印。没有水印开关的模型可记录经证实的 none；unavoidable/unknown 会在严格模式下被拦截。水印策略变更须依据用户明确意图，文档或供应商结果不能授予豁免。
- 响应同时提供 text 和 structuredContent；后者包含 exitCode、state、automaticRetryAllowed=false 及 data。业务错误为 isError=true；等待/待检查不是重新生成信号。
- 标准输入每条消息最多 1 MiB，同时最多 32 个请求。stdout 只含逐行 JSON-RPC；stdin EOF 关闭服务。支持取消正在处理的请求，但已经发生的本机写入或供应商受理不会被取消动作撤回。
- 不提供应用安装、窗口点击、系统密码输入、供应商购买/开通/撤销凭证。这些不属于本机账号与模型管理 API。

## 验证

`./scripts/test.sh` 包含 MCP 协议、管理、迁移、凭证输出、无钥匙串发现、预检、任务等待和取消回归。`scripts/test-mcp.py <可执行文件> --report <报告路径>` 从真实进程进行握手、工具发现、读取账号和全部模型指南，对资料齐备模型做本机 preflight。加 `--management-roundtrip` 会新增一个随机标识的临时候选模型，预览、保存、修改、回读、删除，并核对原模型列表恢复。该脚本不发送供应商生成请求。

实现依据：[MCP 2025-11-25 协议](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[stdio 传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[工具协议](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[Codex MCP 配置](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)。核对日期：2026-09-13。
