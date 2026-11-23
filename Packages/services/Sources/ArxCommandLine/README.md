# ArxCommandLine

The `arx` command, run by the ArxMCP executable: `setup`, `remove`, `status`, `guide` and `mcp`. Uses swift-argument-parser for commands, Promptberry for prompts, swift-subprocess for `claude` and `open`, and AgentToolsClient's `AgentConfigFiles` for other tools' configuration (Claude Desktop, Codex and Cursor).

Exit codes are 0 done, 1 failed, 2 usage and 3 needs a person. ArgumentParser's usage failures are mapped to 2.

Leaving out the target of `setup` or `remove` prompts only at a terminal. Without one it's a usage error, so an agent never waits on a prompt. The prompt only chooses a target: connecting an agent is still confirmed in Arx, so an agent can't approve itself here.

Started bare with `ARX_MCP_SOCKET` set, as the app's copied configuration does, the executable is the MCP server directly.

`arx setup command` copies the helper to `~/.local/bin/arx` with `CommandLineTool`, the same as Arx's Install button. It replaces a link from an older setup, does nothing when run from the installed copy, and never replaces a file that isn't Arx's. The 0600 credential file uses FileManager, because Files has no API for permissions.
