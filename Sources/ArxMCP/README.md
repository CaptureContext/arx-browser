# ArxMCP

Thin executable entry point for the bundled local MCP stdio helper. Protocol and IPC behavior live in BrowserMCPServer and BrowserAutomationClient. Xcode embeds this executable at `Arx.app/Contents/Helpers/ArxMCP`; SwiftPM builds the same source for protocol interoperability tests.

Linked as `arx`, the same executable is the setup command: `arx setup`, `remove`, `status`, `guide` and `mcp`. They live in ArxCommandLine.
