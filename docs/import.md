# 旧格式资料导入

导入器兼容本项目早期使用的特定文件结构，不是任意 Markdown、CSV 或其他密码管理器的通用导入器。新用户可以直接从 GUI 或管理命令创建账号。

点击“导入”后选择资料根目录，先查看账号预览，再确认保存。命令行等价入口：

```bash
keyman import-preview /absolute/path/to/api-records --json
keyman import-commit /absolute/path/to/api-records --json
keyman import-check /absolute/path/to/api-records --json
```

当前解析要求根目录中有 `火山方舟/` 和 `阿里百炼/`。具体文件名、字段及**合成凭证**示例见 [Legacy 测试夹具](../Tests/KeymanCoreTests/Fixtures/Legacy)。这些夹具只能用于测试，不是真实服务配置。

`import-preview` 读取所选资料，不访问钥匙串或调用供应商。`import-commit` 保存并回读核对凭证；不同 Key 会阻止覆盖，相同 Key 保留已有配置。`import-check` 比较来源与已保存凭证，不发送供应商请求。

旧凭证库迁移使用 `keyman vault migrate`。只有确认来源文件里的 Key 仍是当前版本时，才能使用 `--source /absolute/path --source-current`。不要用旧导入文件覆盖已轮换的凭证。
