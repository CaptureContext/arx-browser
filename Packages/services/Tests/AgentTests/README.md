# AgentTests

Tests for [AgentClient](../../Sources/AgentClient/README.md), [ClaudeAgentClient](../../Sources/ClaudeAgentClient/README.md) and [CodexAgentClient](../../Sources/CodexAgentClient/README.md). Nothing touches the real home folder, a real Claude account or a real ChatGPT account.

- `AgentStoreTests` covers per-profile saving, listing and deletion, ephemeral chats that are never written, the 20-minute expiry, the transcript ledger and sweep, conversations copied between profiles, private file permissions, per-profile settings with ephemeral as the default, and discarding the provider's copy.
- `AgentEventTests` covers text batching, ordering and attached context.
- `ClaudeAgentTests` runs the adapter over a temporary home folder and a fake `AgentProcessRunner`. It covers sign-in states, the exact `claude` arguments including effort and the turn cap, the stripped environment, the per-turn credential file, streaming, failures and cancellation, and transcript deletion.
- `CodexAgentTests` runs the Codex adapter over a temporary home folder and a fake `AgentProcessRunner`. It covers sign-in states read from `codex login status`, the model list, the exact `codex exec` arguments including disabled tools, effort and folder trust, the stripped environment, the per-turn `0600` tool configuration, resuming, failure messages and retries, the tool-call cap, denied tools, cancellation, and thread deletion.
