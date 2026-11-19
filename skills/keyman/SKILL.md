---
name: keyman
description: 通过本机 Keyman CLI 查询账号、模型与调用指南，并在授权后用其中保存的密钥调用服务商 API。当用户说"用 Keyman 查一下"、"去 Keyman 拿密钥/key"、"从 Keyman 里找模型"，或说"用 <服务商> 的 <模型> 做 <任务>"（如火山方舟/Ark、阿里百炼、Vidu、MiniMax、火山语音、腾讯混元 3D/TokenHub 的文生图、视频、语音、3D、对话）且需要 API 密钥时使用。Use when the user mentions Keyman, asks to fetch an API key/credentials, or wants to call a provider model whose credentials live in Keyman. 不要用于 SIL Keyman 输入法。
---

# Keyman（本机 API 密钥与模型管理器）

Keyman 是 macOS app，账号、模型、调用指南存在本机，密钥在钥匙串。CLI：`~/.local/bin/keyman`（不在 PATH 时用绝对路径）。若已配置 MCP（`keyman_*` 工具），语义相同，优先用 MCP。

## 核心规则

1. **不要读取、打印、复述完整密钥**，也不要让用户在聊天里贴密钥。"拿密钥"的意思是让 Keyman 代为调用，不是把 key 取出来。设置密钥只用 `keyman key set <账号> --key-file <私有文件>` 或 `--key-stdin`，绝不放进命令行参数。
2. **`call` 会真实请求服务商并可能产生费用**：执行前必须得到用户对本次任务和费用的明确同意。
3. **退出码 3（等待中／成品检查未完成）不是失败，不要重新生成。** 用 `task` 查询原任务。网络超时也不代表服务商没收到，同样不要重复提交。
4. 避免 `keyman run`：它把原始密钥注入子进程。仅当用户明确要求且没有更安全的方式时使用，并告知风险。
5. 管理类写操作先 `--dry-run`，确认预览后再正式执行，并回读结果。

## 流程

按下面顺序，前五步都是只读、不联网、不碰密钥：

1. **`keyman list --json`** 看有哪些账号（alias、服务商、模型数）。模型数为 0 的账号通常只存凭据。
2. **`keyman catalog <用途关键词> --json`** 按用途找模型，如 `catalog 视频`、`catalog speech`。用户指定了服务商时，只看对应账号：`keyman models <账号> --json`。
3. **`keyman guide <账号> <模型> --json`** 读使用说明：输入输出、步骤、限制、缺项。有缺项就先补齐或告诉用户，不要凭空编造音色 ID 等私有参数。
4. **`keyman example <账号> <模型> > /absolute/scratch/request.json`** 导出请求体，按本次任务修改。临时文件放 scratchpad，不要放进 Git 仓库。
5. **`keyman preflight <账号> <模型> --body @request.json`** 检查参数、启用状态、水印要求。`requestReady` 只代表本地配置完整，不代表凭据或服务可用。
6. **向用户确认**：说明账号、模型、请求要点和可能的费用，得到明确同意后才继续。
7. **`keyman call <账号> <模型> --body @request.json`** 发起调用。图像/视频默认检查可见水印；`--allow-watermark` 只有用户明确同意才加。
8. **异步任务**：记下返回的任务编号，用 `keyman task <账号> <模型> <任务编号> --wait-seconds 60` 反复查询同一个任务，直到完成。成功后对成品再做 `keyman verify <文件>`，并自己看一遍质量。

汇报时分开说明：配置是否就绪、凭据是否可访问、服务商是否成功、成品质量如何。

## 常见情形

- **"用 Keyman 查一下"**：只做步骤 1，必要时加 2。汇报账号和模型清单，不调用。
- **"用 X 的 Y 模型做 Z"**：先 `list` 定位账号，再走 2 到 6，给用户确认后才 `call`。找不到匹配的账号或模型时，如实说明，并建议用户在 Keyman 里添加，不要换成别家模型代跑。
- **同一用途有多个候选账号**：列出差别（服务商、区域、项目），让用户选。
- **账号有模型但没有密钥**：`keyman key status <账号>` 查看（只显示后缀）。没有就请用户在 app 里用安全输入框设置。
- **系统弹出钥匙串授权**：这一步必须由用户在界面上点，不要尝试绕过。

## 余额

Keyman **不能查询余额**，只保存每个账号的余额页链接（`balanceURL`），在 app 里点余额按钮会用浏览器打开。用户问余额时：用 `keyman list --json` 读 `balanceURL`，把链接告诉用户，让用户自己查看，不要编造数字，也不要去请求该页面。没有链接就如实说明，并建议用 `keyman profile update <账号> --file`（先 `--dry-run`）补上，内容形如 `{"balanceURL": "https://…"}`。

## 配置管理

`profile`、`endpoint`、`model`、`key` 子命令可增删改账号、接口、模型和使用指南，详见 `docs/management.md`。修改前先 `get` 看现状，写入前先 `--dry-run`，更新文件只含要改的字段，`null` 清空可选字段。删除账号只移除本地凭据，不会在服务商那边吊销密钥。
