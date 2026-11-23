"""Agent behavior evals (DEV-1026): scripted agents against the real MCP server.

`make agent-evals` builds the signed app with the engine, or takes `ARGS='--app PATH'`, and runs
each task in its own `Arx --headless` run on a loopback fixture. A stand-in agent drives the
bundled `ArxMCP` helper the way the arx-browser skill teaches, and the run records what that
cost: tool calls, and the bytes and approximate tokens of tool descriptions, arguments and
results. Results are compared with `baseline.json`; `--record` rewrites it. Nothing gates CI.

`ARGS='--model claude'` hands the same tasks to Claude Code instead, run by hand: it spends
real tokens on your plan.
"""
