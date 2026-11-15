# Legacy import

The importer supports a specific directory structure used by early versions of this project. It is not a general importer for arbitrary Markdown, CSV, or other password managers. New users can create accounts directly through the GUI or management commands.

Choose **Import** (currently labeled `导入`), select the source directory, review the preview, and confirm the import. Equivalent CLI commands:

```bash
keyman import-preview /absolute/path/to/api-records --json
keyman import-commit /absolute/path/to/api-records --json
keyman import-check /absolute/path/to/api-records --json
```

The parser currently requires `火山方舟/` and `阿里百炼/` under the source root. These Chinese directory names and source field names are part of the legacy format and must remain unchanged. See the [legacy fixtures](../Tests/KeymanCoreTests/Fixtures/Legacy) for exact filenames, fields, and **synthetic credentials**. The fixtures are for testing, not live service configuration.

`import-preview` reads the selected files without accessing Keychain or calling providers. `import-commit` saves credentials and reads them back for verification: a different key stops the import instead of overwriting the existing credential; a matching key preserves existing configuration. `import-check` compares source credentials with stored credentials without calling providers.

Use `keyman vault migrate` to migrate older credential storage. Use `--source /absolute/path --source-current` only after confirming that the source files contain the current keys. Do not overwrite rotated credentials with old import files.
