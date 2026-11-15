# Keyman

**为本机 AI Agent 管理 API 凭证、账号、接口和模型。**

Keyman 是一个 macOS 应用，同时提供 CLI 和 30 个 stdio MCP 工具。你在本机保存 API Key，Agent 按账号与模型调用服务；常规查询和模型说明不返回完整凭证。

Local API credential and model manager for macOS, with a native app, CLI, and stdio MCP server. Credentials live in macOS Keychain. MIT licensed.

## 能做什么

- 用一个界面管理多个供应商的账号、认证方式、接口和模型。
- 为模型维护用途、输入输出、官方资料、请求示例和异步任务查询规则。
- 让 Agent 按用途搜索模型，阅读指南，预检请求，再在授权范围内调用。
- 通过 macOS 钥匙串保存凭证，支持替换、清除、迁移及状态查询。
- 在默认输出规则下检查图片与视频的常见可见文字水印；保留待检查状态，避免自动重复提交生成任务。

支持配置通用 REST 接口，并有火山方舟、百炼、火山语音及 Vidu 的部分流程适配。支持范围取决于具体接口契约；供应商权限、计费和模型可用性由供应商决定。仓库不附带任何真实账号、Key 或付费调用额度。

## 从源码安装

需要 **macOS 14+、Swift 6+、Python 3.10+**，以及提供这些版本的 Apple Command Line Tools 或 Xcode。GUI 当前为中文。此版本处于 0.x 阶段。

```bash
git clone https://github.com/elfish2025-crypto/keyman.git
cd keyman
./scripts/test.sh
python3 -m unittest discover -s Tests/Installation
./scripts/package-app.sh
./scripts/install-local.sh
open "$HOME/Applications/Keyman.app"
```

打包输出为 `dist/Keyman.app.zip`；安装脚本将应用放入 `~/Applications`，建立 `~/.local/bin/keyman` 链接。若已安装 Keyman，先退出应用及使用它的 MCP 进程。安装器会归档被替换版本；账号配置与凭证不作为安装包内容。

当前使用本机 ad-hoc 签名，没有 Apple Developer ID 签名或公证。源码构建是本次公开版本的安装方式；重新构建后，macOS 可能再次要求钥匙串授权。

以下命令假定 `~/.local/bin` 已加入 PATH，否则使用 `"$HOME/.local/bin/keyman"`。

## 第一次使用

打开应用，点击“添加账号”，选择供应商或自定义 REST，填写自己的接口与认证方式。Key 可以稍后设置。再添加模型及用途指南。所有账号、接口和模型也能用 CLI 或 MCP 管理。

仓库中的示例使用 `example.invalid` 和候选模型，供理解配置结构，不能直接调用真实服务：

```bash
keyman profile add --file examples/management-profile.json --dry-run
keyman profile add --file examples/management-profile.json
keyman endpoint add example-account --file examples/management-endpoint.json
keyman model add example-account --file examples/management-model.json
keyman model update example-account text-model --file examples/management-model-guide.json
keyman guide example-account text-model --json
```

在调用前，按供应商官方资料补全真实接口、认证方式、模型编号和请求示例。配置变更会使旧示例失效；重新提交 `usageGuide.requestExample` 表示已重新核对。

完整 Key 通过应用的安全输入框，或本机私有文件/标准输入保存。不要把它写进命令参数、模型示例、Git 仓库或聊天记录：

```bash
keyman key set example-account --key-file /absolute/private/path/key.txt
keyman key status example-account
```

## Agent 调用流程

```bash
keyman catalog 配音 --json
keyman guide my-account my-model --json
keyman example my-account my-model > request.json
# 根据本次任务编辑 request.json
keyman preflight my-account my-model --body @request.json
# 获得本次任务及费用授权后执行：
keyman call my-account my-model --body @request.json
```

`catalog`、`guide`、`example` 和 `preflight` 不调用供应商。`requestReady` 只表示本机资料齐备，不证明凭证有效、服务开通或结果合格。`call` 会发起真实请求，可能计费。

异步请求返回任务编号后，用 `keyman task my-account my-model TASK_ID --wait-seconds 60` 查询同一个任务。退出码 `3` 表示等待或成品检查未完成，不是重新生成的信号。网络超时也不能证明供应商没有受理。

连接 Agent 的配置及工具清单见 [MCP 文档](docs/mcp.md)。业务管理见 [管理命令](docs/management.md) 和 [Agent 管理范围](docs/agent-management.md)。旧格式资料导入见 [导入说明](docs/import.md)。

## 凭证与输出边界

凭证保存在 macOS Keychain 的统一条目 `com.local.keyman.vault / credentials-v1`。账号和模型配置位于 `~/Library/Application Support/Keyman/config.json`，调用及检查记录位于该目录的 `Calls/`。这些是个人数据，不应提交到仓库。

系统授权需要用户在 macOS 窗口完成。清除本机 Key 不会撤销供应商端凭证。不要用旧版本应用修改新版本配置。完整安全边界和报告方式见 [SECURITY.md](SECURITY.md)。

默认要求无可见水印：未知或不可避免的水印能力会在请求前阻止调用。能力结论应有具体模型和接口依据。图片使用 Vision OCR；视频检查首尾及约每两秒的抽样帧，支持最长 180 秒、单文件最大 200 MiB。它可能漏检图形标记、短暂水印或模糊文字，也不检查隐形水印；通过自动检查不等于完成画面、声音或内容验收。

CLI 的 `run` 兼容模式会将凭证放入所启动程序的环境变量，因此只能运行可信程序。严格输出规则下，该模式需要明确选择 `--allow-unchecked-output`；MCP 不开放通用 shell 或 Key 导出工具。

## 开发

`Sources/KeymanCore` 实现配置、凭证、请求及管理逻辑；`KeymanCLI` 提供 CLI 和 MCP；`KeymanAppSupport` 与 `KeymanApp` 提供 SwiftUI 界面及应用入口。

项目没有第三方 Swift Package 依赖。测试使用合成凭证和模拟服务；请勿向测试夹具放入真实 Key。提交方式见 [CONTRIBUTING.md](CONTRIBUTING.md)，版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE) © 2026 elfish2025-crypto。项目与各 API 供应商无隶属关系。
