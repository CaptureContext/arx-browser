"""What a task cost an agent: tool calls, and what it read and wrote.

Sizes are UTF-8 bytes of what a model sees: the server's `initialize` instructions; each tool's
name, description and input schema from `tools/list`; the arguments it sends, as compact JSON;
and a result's text content. Images are counted apart, since models price them by pixels, not
bytes. Tokens are estimated at four bytes each, the usual figure for English and JSON; compare
runs with each other, not with a bill.

A client sends the instructions and the tool list with every model pass. `perTurn` is what that
costs on average over a task's calls, and `allTurns` adds it to every call as if each were a pass of
its own, which is what a model that calls one tool at a time pays (DEV-1021).
"""

import json
from dataclasses import dataclass, field

BYTES_PER_TOKEN = 4


def tokens(size):
    """Approximate tokens for `size` UTF-8 bytes, rounded up."""
    return -(-size // BYTES_PER_TOKEN)


def compact(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def size(text):
    return len(text.encode("utf-8"))


def description_size(tools):
    """Bytes of the tool list a model is given: name, description and input schema of each tool."""
    return sum(size(compact({key: tool.get(key) for key in ("name", "description", "inputSchema")}))
               for tool in tools)


def result_text(result):
    """The text a model reads from a tools/call result, and how many images came with it."""
    texts, images = [], 0
    for item in result.get("content") or []:
        if item.get("type") == "text":
            texts.append(item.get("text", ""))
        elif item.get("type") == "image":
            images += 1
    return "\n".join(texts), images


def error_code(result):
    """The error code of a failed call, or None. Arx puts it in the structured result."""
    if not result.get("isError"):
        return None
    structured = (result.get("structuredContent") or {}).get("result")
    if isinstance(structured, dict) and structured.get("code"):
        return structured["code"]
    return "error"


@dataclass
class Call:
    tool: str
    argument_bytes: int
    result_bytes: int
    images: int
    error: str | None
    # The instructions and tool list a model held when it made the call.
    context_bytes: int = 0


@dataclass
class Usage:
    tools: int = 0
    polls: int = 0
    instruction_bytes: int = 0
    description_bytes: int = 0
    calls: list[Call] = field(default_factory=list)

    def initialized(self, result):
        self.instruction_bytes = size(result.get("instructions") or "")

    def listed(self, tools):
        """The tool list as a model last saw it; a later list (after a grant change) replaces it."""
        self.tools = len(tools)
        self.description_bytes = description_size(tools)

    def observe(self, request, response, context=None):
        """Accounts one JSON-RPC exchange, from either the stand-in agent or a relayed real client.
        A tools/call the server rejects (invalid arguments) still cost a call and its reply.
        `context` is what `context_bytes` was when the request was sent, for a reply that may come
        after a newer tool list; without it, it's read now."""
        context = self.context_bytes() if context is None else context
        method = request.get("method")
        result = response.get("result")
        if result is None:
            if method == "tools/call" and "error" in response:
                params = request.get("params") or {}
                error = response["error"]
                text = compact(error)
                self.calls.append(Call(params.get("name", ""), size(compact(params.get("arguments") or {})),
                                       size(text), 0, str(error.get("code", "error")), context))
            return
        if method == "initialize":
            self.initialized(result)
        elif method == "tools/list":
            self.listed(result.get("tools") or [])
        elif method == "tools/call":
            params = request.get("params") or {}
            self.called(params.get("name", ""), params.get("arguments") or {}, result, context)

    def called(self, tool, arguments, result, context=None):
        text, images = result_text(result)
        context = self.context_bytes() if context is None else context
        call = Call(tool, size(compact(arguments)), size(text), images, error_code(result), context)
        self.calls.append(call)
        return call

    def context_bytes(self):
        return self.instruction_bytes + self.description_bytes

    def summary(self):
        """The per-task figures the report and the baseline keep."""
        by_tool = {}
        for call in self.calls:
            by_tool[call.tool] = by_tool.get(call.tool, 0) + 1
        arguments = sum(call.argument_bytes for call in self.calls)
        results = sum(call.result_bytes for call in self.calls)
        context = self.context_bytes()
        turns = [call.context_bytes for call in self.calls] or [context]
        return {
            "calls": len(self.calls),
            "polls": self.polls,
            "work": len(self.calls) - self.polls,
            "errors": sum(1 for call in self.calls if call.error),
            "byTool": dict(sorted(by_tool.items())),
            "tools": self.tools,
            "bytes": {
                "instructions": self.instruction_bytes, "descriptions": self.description_bytes,
                "arguments": arguments, "results": results,
            },
            "tokens": {
                "instructions": tokens(self.instruction_bytes),
                "descriptions": tokens(self.description_bytes),
                "arguments": tokens(arguments),
                "results": tokens(results),
                "total": tokens(context) + tokens(arguments) + tokens(results),
                "perTurn": tokens(sum(turns) // len(turns)),
                "allTurns": sum(tokens(turn) for turn in turns) + tokens(arguments) + tokens(results),
            },
            "images": sum(call.images for call in self.calls),
        }
