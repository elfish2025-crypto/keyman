#!/usr/bin/env python3
"""Exercise the real stdio process without submitting any provider generation request."""
import argparse
import json
import os
import pathlib
import queue
import subprocess
import threading
import time
import uuid


class Client:
    def __init__(self, executable):
        self.process = subprocess.Popen([executable, "mcp"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.replies = queue.Queue()
        self.next_id = 0
        self.stderr = bytearray()
        def read_stdout():
            for line in self.process.stdout:
                try:
                    self.replies.put(json.loads(line))
                except Exception:
                    self.replies.put(RuntimeError("Non-protocol stdout"))
            self.replies.put(EOFError("Server closed stdout"))
        def read_stderr():
            # Drain without displaying possible external diagnostics.
            for chunk in iter(lambda: self.process.stderr.read(4096), b""):
                self.stderr.extend(chunk[:4096])
        threading.Thread(target=read_stdout, daemon=True).start()
        threading.Thread(target=read_stderr, daemon=True).start()

    def send(self, method, params=None, request_id=None):
        value = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            value["params"] = params
        if request_id is not None:
            value["id"] = request_id
        self.process.stdin.write(json.dumps(value, ensure_ascii=False).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params=None, timeout=15):
        self.next_id += 1
        self.send(method, params, self.next_id)
        result = self.replies.get(timeout=timeout)
        if isinstance(result, Exception):
            raise result
        assert result.get("jsonrpc") == "2.0" and result.get("id") == self.next_id
        assert "error" not in result, "MCP protocol error"
        return result["result"]

    def tool(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        assert not result.get("isError"), "Tool failed: " + name
        assert json.loads(result["content"][0]["text"]) == result["structuredContent"]
        return result["structuredContent"]["data"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
            raise AssertionError("MCP did not stop after stdin EOF")
        assert self.process.returncode == 0
        assert not self.stderr, "Unexpected MCP stderr"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--management-roundtrip", action="store_true",
                        help="Create/read/update/delete one temporary candidate model; no Key changes")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    client = Client(args.executable)
    report = {"generationRequestsSent": 0, "credentialValuesRequested": False,
              "executable": str(pathlib.Path(args.executable).resolve())}
    temporary = None
    try:
        initialized = client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                    "clientInfo": {"name": "keyman-acceptance", "version": "1"}})
        assert initialized["protocolVersion"] == "2025-11-25"
        report["serverInfo"] = initialized["serverInfo"]
        client.send("notifications/initialized")
        definitions = client.request("tools/list")["tools"]
        names = [tool["name"] for tool in definitions]
        assert len(names) == len(set(names))
        assert "keyman_manage_model" in names and "keyman_call" in names
        assert not any(name in names for name in ["keyman_run", "keyman_export_key"])
        report["toolCount"] = len(names)
        report["toolNames"] = names
        accounts = client.tool("keyman_accounts")["data"]
        report["accountCount"] = len(accounts)
        vault = client.request("tools/call", {"name": "keyman_vault_status", "arguments": {}})
        report["vault"] = {"isError": vault.get("isError", False), "result": vault.get("structuredContent")}
        catalog = client.tool("keyman_catalog")
        checks = []
        for account in catalog:
            alias = account["profileAlias"]
            for model in account["models"]:
                guide = client.tool("keyman_guide", profile=alias, model=model["modelAlias"])
                item = {"profile": alias, "model": model["modelAlias"], "requestReady": guide["requestReady"]}
                if guide["requestReady"]:
                    example = client.tool("keyman_example", profile=alias, model=model["modelAlias"])
                    preflight = client.tool("keyman_preflight", profile=alias, model=model["modelAlias"], body=example)
                    assert preflight["ok"] and not preflight["networkRequest"] and not preflight["credentialRead"]
                    item["preflightPassed"] = True
                checks.append(item)
        report["models"] = checks
        if args.management_roundtrip:
            assert accounts
            profile = accounts[0]["alias"]
            before = client.tool("keyman_models", profile=profile)
            alias = "mcp-acceptance-" + uuid.uuid4().hex[:10]
            document = {"alias": alias, "name": "MCP 临时验收模型", "modality": "other",
                        "status": "candidate", "usageGuide": {"summary": "仅验证本机管理，不调用供应商"}}
            preview = client.tool("keyman_manage_model", action="add", profile=profile, document=document)
            assert preview["dryRun"]
            assert client.tool("keyman_models", profile=profile) == before
            client.tool("keyman_manage_model", action="add", profile=profile, document=document, dryRun=False)
            temporary = (profile, alias)
            client.tool("keyman_manage_model", action="update", profile=profile, model=alias,
                        document={"usageGuide": {"summary": "MCP 保存回读验收"}}, dryRun=False)
            readback = client.tool("keyman_guide", profile=profile, model=alias)
            assert readback["guide"]["summary"] == "MCP 保存回读验收"
            client.tool("keyman_manage_model", action="delete", profile=profile, model=alias, dryRun=False)
            temporary = None
            assert client.tool("keyman_models", profile=profile) == before
            report["managementRoundtrip"] = "preview-add-update-read-delete-restored"
        report["ok"] = True
    finally:
        if temporary:
            # Delete only this test's generated candidate; never alter an existing model.
            client.tool("keyman_manage_model", action="delete", profile=temporary[0], model=temporary[1], dryRun=False)
        client.close()
        destination = pathlib.Path(args.report)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ["ok", "serverInfo", "toolCount", "accountCount", "managementRoundtrip", "generationRequestsSent"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
