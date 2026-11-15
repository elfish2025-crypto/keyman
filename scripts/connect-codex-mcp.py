#!/usr/bin/env python3
"""Register the installed Keyman with Codex, preserving all unrelated configuration."""
import argparse
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex", default=shutil.which("codex"))
    args = parser.parse_args()
    if not args.codex:
        raise SystemExit("Codex CLI not found; provide --codex /absolute/path/to/codex")
    executable = pathlib.Path.home() / ".local/bin/keyman"
    if not executable.is_file():
        raise SystemExit("Install Keyman before connecting MCP")
    def get():
        return subprocess.run([args.codex, "mcp", "get", "keyman", "--json"], capture_output=True, text=True)
    current = get()
    if current.returncode:
        if "No MCP server named 'keyman' found" not in current.stderr:
            raise SystemExit("Could not inspect Codex MCP configuration; no changes made")
        subprocess.run([args.codex, "mcp", "add", "keyman", "--", str(executable), "mcp"], check=True)
        current = get()
    current.check_returncode()
    definition = json.loads(current.stdout)
    transport = definition["transport"]
    if transport.get("command") != str(executable) or transport.get("args") != ["mcp"]:
        raise SystemExit("Existing keyman MCP points elsewhere; retained for review")
    codex_directory = pathlib.Path(os.environ.get("CODEX_HOME", str(pathlib.Path.home() / ".codex")))
    config = codex_directory / "config.toml"
    original = config.read_text()
    pattern = r'(?m)^\[mcp_servers\.keyman\][ \t]*\n(?P<body>.*?)(?=^\[|\Z)'
    match = re.search(pattern, original, re.DOTALL | re.MULTILINE)
    if not match:
        raise SystemExit("Expected MCP table missing; no manual rewrite attempted")
    block = match.group(0)
    for key, value in [("startup_timeout_sec", "15"), ("tool_timeout_sec", "240"), ("enabled", "true")]:
        setting = re.compile(r"(?m)^" + key + r"\s*=.*$")
        if setting.search(block):
            block = setting.sub(key + " = " + value, block)
        else:
            block = block.rstrip() + "\n" + key + " = " + value + "\n\n"
    updated = original[:match.start()] + block + original[match.end():]
    if updated != original:
        with tempfile.NamedTemporaryFile(mode="w", dir=codex_directory, prefix=".keyman-mcp-", delete=False) as handle:
            temporary = pathlib.Path(handle.name)
            try:
                os.chmod(temporary, stat.S_IMODE(config.stat().st_mode))
                handle.write(updated)
                handle.flush()
                os.fsync(handle.fileno())
                if config.read_text() != original:
                    raise RuntimeError("Codex configuration changed concurrently; refresh before retrying")
                os.replace(temporary, config)
            finally:
                temporary.unlink(missing_ok=True)
    verified = get()
    verified.check_returncode()
    result = json.loads(verified.stdout)
    assert result["enabled"] and result["tool_timeout_sec"] == 240
    print(json.dumps({"name": result["name"], "enabled": result["enabled"],
                      "command": result["transport"]["command"], "args": result["transport"]["args"],
                      "startup_timeout_sec": result["startup_timeout_sec"],
                      "tool_timeout_sec": result["tool_timeout_sec"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
