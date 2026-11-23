"""The MCP side of an eval: the stand-in agent's client, and a relay that records a real one.

Both talk to the helper the run's configuration names (`mcpServers.arx`), over newline-delimited
JSON-RPC on stdio, and every exchange goes through `Usage.observe`, so a scripted run and a real
model's run are measured the same way.
"""

import json
import subprocess
import sys
from pathlib import Path

from .scenarios import Reply, TaskFailure

PROTOCOL_VERSION = "2025-11-25"


def server(configuration, listing=None):
    """The `arx` server entry of a headless run's MCP configuration. `listing` (`core` or `all`)
    chooses the helper's tool listing; without it the helper chooses by the client's name."""
    entry = json.loads(Path(configuration).read_text())["mcpServers"]["arx"]
    if listing:
        entry["env"] = {**entry.get("env", {}), "ARX_MCP_TOOLS": listing}
    return entry


class Session:
    """The stand-in agent's MCP client. `tools` holds the tool names the server listed."""

    def __init__(self, configuration, usage, log=None, listing=None):
        entry = server(configuration, listing)
        self.usage = usage
        self.log = log
        self.process = subprocess.Popen(
            [entry["command"], *entry.get("args", [])], env=entry["env"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.next_id = 0
        self.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION, "capabilities": {},
            "clientInfo": {"name": "arx-agent-evals", "version": "1"},
        })
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.tools = self.list_tools()

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.send(request)
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise ValueError(f"The MCP helper closed during {method}")
            response = json.loads(line)
            if response.get("id") != self.next_id:
                continue  # A notification, such as tools/list_changed.
            self.usage.observe(request, response)
            if "error" in response:
                # A rejected tool call is the agent's failure; anything else means the session broke.
                failure = TaskFailure if method == "tools/call" else ValueError
                raise failure(f"MCP {method} failed: {response['error']}")
            return response["result"]

    def list_tools(self):
        tools, cursor = [], None
        while True:
            result = self.request("tools/list", {"cursor": cursor} if cursor else {})
            tools += result.get("tools") or []
            cursor = result.get("nextCursor")
            if not cursor:
                break
        self.usage.listed(tools)
        return {tool["name"] for tool in tools}

    def call(self, tool, arguments):
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        structured = result.get("structuredContent") or {}
        value = structured.get("result")
        value = dict(value) if isinstance(value, dict) else {}
        if isinstance(structured.get("snapshot"), dict):
            # returnSnapshot: the next snapshot rides beside the action's result.
            snapshot = structured["snapshot"]
            value["snapshot"] = snapshot.get("result", snapshot)
        failed = result.get("isError") or value.get("kind") == "error"
        if self.log:
            outcome = f"{value.get('code') or 'error'} {json.dumps(value)[:2000]}" if failed else value.get("kind", "ok")
            self.log.write(f"  {tool} -> {outcome}\n")
        if failed:
            return Reply(False, value, value.get("code") or "error")
        return Reply(True, value, None)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()


# MARK: - Relay for a real client

def relay_configuration(configuration, transcript, listing=None):
    """An MCP configuration whose `arx` server is this relay in front of the run's helper."""
    entry = server(configuration, listing)
    return {"mcpServers": {"arx": {
        "command": sys.executable,
        "args": ["-I", str(Path(__file__).with_name("relay.py").resolve()), str(transcript), entry["command"],
                 *entry.get("args", [])],
        "env": entry["env"],
    }}}


def account(transcript, usage):
    """Replays a relay transcript into `usage`: each request with the response to its id, and the
    instructions and tool list the client held when it sent the request."""
    pending = {}
    for line in Path(transcript).read_text().splitlines():
        record = json.loads(line)
        message = record["message"]
        if record["from"] == "client" and "method" in message and "id" in message:
            pending[message["id"]] = (message, usage.context_bytes())
        elif record["from"] == "server" and message.get("id") in pending:
            request, context = pending.pop(message["id"])
            usage.observe(request, message, context)
