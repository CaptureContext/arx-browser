"""The optional real-model mode: Claude Code does the task instead of a stand-in agent.

Run by hand (`make agent-evals ARGS='--model claude'`); each task spends a short answer's worth of
tokens on the signed-in plan. Claude Code gets only the run's `arx` server, through the recording
relay, has none of its own built-in tools, and is asked for a one-line answer. Its own token count
comes from the stream's final `result` message.
"""

import json
import shutil
import subprocess
from pathlib import Path

from .scenarios import TaskFailure
from .session import account, relay_configuration

SYSTEM = (
    "You are being evaluated on how you use the Arx browser's MCP tools. Use only the arx tools. "
    "When you're done, answer in one line."
)


def command(executable, prompt, configuration, model=None):
    arguments = [
        executable, "-p", prompt, "--output-format", "stream-json", "--verbose",
        "--mcp-config", str(configuration), "--strict-mcp-config",
        # No built-in tools, so every step goes through the recorded arx server.
        "--tools", "", "--allowedTools", "mcp__arx", "--append-system-prompt", SYSTEM,
    ]
    return arguments + (["--model", model] if model else [])


def parse(lines):
    """The answer and Claude Code's own figures from its stream-json output."""
    answer, figures, tool_uses = "", {}, 0
    for line in lines:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("type") == "assistant":
            content = (message.get("message") or {}).get("content") or []
            tool_uses += sum(1 for item in content if item.get("type") == "tool_use")
        elif message.get("type") == "result":
            answer = message.get("result") or ""
            usage = message.get("usage") or {}
            figures = {
                "turns": message.get("num_turns"),
                "inputTokens": usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0),
                "outputTokens": usage.get("output_tokens", 0),
                "costUSD": message.get("total_cost_usd"),
            }
    figures["toolUses"] = tool_uses
    return answer.strip(), figures


def run(task, fixture, configuration, usage, workspace, options):
    """Has Claude Code do `task`; its answer and figures. The relay's transcript fills `usage`."""
    executable = options.claude or shutil.which("claude")
    if not executable:
        raise ValueError("Claude Code isn't installed; pass ARGS='--claude PATH'")
    transcript = Path(workspace) / f"{task.name}.jsonl"
    relayed = Path(workspace) / f"{task.name}-mcp.json"
    relayed.write_text(json.dumps(relay_configuration(configuration, transcript, options.tools)))
    relayed.chmod(0o600)
    try:
        finished = subprocess.run(
            command(executable, task.ask(fixture), relayed, options.claude_model),
            capture_output=True, text=True, timeout=options.claude_timeout, cwd=workspace,
        )
    except subprocess.TimeoutExpired:
        finished = None
    finally:
        # What it did before a timeout still counts.
        if transcript.exists():
            account(transcript, usage)
    if finished is None:
        raise TaskFailure(f"Claude Code took longer than {options.claude_timeout} s")
    answer, figures = parse(finished.stdout.splitlines())
    if finished.returncode != 0 and not answer:
        raise ValueError(f"Claude Code exited {finished.returncode}: {finished.stderr.strip()[-400:]}")
    return answer, figures
