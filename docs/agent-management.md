# Agent 管理 Keyman 的范围

本清单对应 Keyman 0.7.4，重点是管理 Keyman 本身。调用配置见 [管理命令](management.md)。

## 接入方式

- 本机命令行：已提供。入口 `~/.local/bin/keyman`，管理操作返回 JSON。
- HTTP 管理 API：尚未提供。没有监听端口或管理服务器。
- MCP 服务：已提供本机 stdio 的 30 个工具，可接入本机 MCP 客户端。工具清单、结构和流程见 [MCP 接入](mcp.md)。
- 图形界面、命令行和 MCP 共用管理与校验逻辑；不要求 Agent 通过界面点击。

因此，“Agent 能管理 Keyman”与“所有操作已有网络 API”是两件事。当前能启动这台 Mac 上 MCP 服务或执行本机命令的 Agent 可以完成业务管理；仅能使用远程网络 API 的 Agent 不能直接连接本机 stdio 服务。

## 界面业务操作与命令对应

| 管理内容 | Agent 入口 | 范围说明 |
|---|---|---|
| 查询账号、项目、区域、工作空间、认证方式 | `list`、`profile get` | 返回配置，不返回完整 Key |
| 新增、修改、改名、启停、删除账号 | `profile add/update/enable/disable/delete` | 删除会移除本机凭证，不撤销供应商端 Key |
| 保存、替换、查询状态、清除 Key | `key set/status/clear` | Key 用标准输入或私有文件提供；状态只显示末四位 |
| 新增、修改、删除接口 | `endpoint add/update/delete` | 不允许删除仍被模型引用的接口 |
| 新增、修改、启停、删除模型 | `model add/update/enable/disable/delete` | 包含模型 ID、调用模板、结果字段等；不能伪造验证成功 |
| 把模型迁到正确凭证账号 | `model move` | 一次保存迁出和迁入，保留模型 ID，不移动或读取 Key |
| 编辑用途、输入输出、步骤、限制、示例 | `model update` 的 `usageGuide` 字段 | 接口变化后请求示例须重新核对 |
| 按用途搜索、阅读指南、导出示例 | `catalog`、`guide`、`example` | 不读取钥匙串、不调用供应商 |
| 补充内置模型说明 | `install-guides` | 只补缺失说明，不覆盖用户说明 |
| 导入预览、保存、核对 | `import-preview/commit/check` | 发现不同 Key 会停止，不擅自覆盖 |
| 凭证库状态、主动授权、迁移 | `vault status/unlock/migrate` | 系统授权弹窗中的密码仍由人输入 |
| 修改默认输出规则 | `policy show/set` | 与界面共用全局输出规则 |
| 登记模型水印能力 | `watermark-config` | 结论绑定具体版本与接口 |
| 检查账号认证配置 | `profile test` | 与真实模型调用结果分开记录 |
| 检查请求、执行模型测试 | `preflight`、`call` | preflight 不调用供应商；call 在任务授权范围内执行 |
| 查询、等待已有生成任务 | `task` | 使用相同账号查询固定任务编号；不重新生成，成功后检查成品 |
| 检查已有图片、视频或响应 | `verify`、`verify-response` | 返回检查结果；不把 HTTP 成功当作成品合格 |
| 刷新读取其他窗口刚保存的内容 | 再次执行查询命令 | 每次查询读取当前配置 |

所有界面业务管理动作都有上述命令入口，部分界面流程对应多条命令。窗口打开、关闭、页面跳转与系统密码输入不属于这些管理命令。

## 软件维护另有入口

应用打包、安装、历史副本归档通过项目中的维护脚本完成：`package-app.sh`、`install-local.sh`、`app_installation.py cleanup`。它们不属于已安装 `keyman` 的管理 API，也未通过 HTTP 或 MCP 提供。

本机删除 Key 与在供应商端撤销 Key 不同；供应商端创建凭证、购买额度、开通模型等也不属于当前 Keyman 的管理范围。

## 验证范围

自动化测试使用合成凭证、临时目录和模拟传输。供应商真实调用、账号授权与成品质量应在各自使用环境单独验证。
