# ClaudeAgentClient

Claude for Arx's agent, through the person's own Claude Code (`@Dependency(\.claudeAgent)`, an `AgentProviderClient` from [AgentClient](../AgentClient/README.md)).

## Why Claude Code

Checked against Anthropic's docs on 8 November 2026 (findings in DEV-644):

- Anthropic doesn't let other apps offer a claude.ai sign-in, route requests through Pro, Max or Ultra credentials, or hold Claude tokens ([Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance), [Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview)).
- The same page allows a person to sign in to the **unmodified Claude Code binary** with their own subscription, including when another product runs it.
- So Arx never signs anyone in and never reads a credential. The person runs `claude auth login`, and Claude Code keeps the login in the macOS Keychain.
- Anthropic may count usage from other tools against paid usage credits instead of the plan's limits ([support](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account)). The UI should say that chats count against the person's Claude plan.

## How a turn runs

1. Find `claude` in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` or `~/.claude/local`.
2. Run `claude auth status` before every turn. Only `authMethod` `claude.ai` is used. Any other method, such as an API key, a key helper or a cloud provider, is billed separately, so it's reported as `unsupportedSignIn` instead of being used.
3. Start `claude --print` with `stream-json` output and the prompt on standard input:
   - `--tools ""`: none of Claude Code's own tools, so no shell, file or web access.
   - `--setting-sources local` and `--strict-mcp-config`, with the profile's empty `Workspace` folder as the working directory, so the person's own hooks, plugins and MCP servers stay out.
   - `--disable-slash-commands` and `--permission-mode dontAsk`.
   - `--system-prompt` with `AgentPrompt.guidance`.
   - `--effort` from the request, `low` by default, and `--max-turns 12`, which caps the tool steps per message. Hitting the cap fails the turn with `turnLimitReached`.
   - `--session-id <new UUID>` for a new chat, or `--resume <token>` to continue one.
   - `--model <alias>` when the profile picked one.
   - `--input-format text`, or `stream-json` when the message carries images or PDFs (DEV-798): then standard input is one user message whose `image` and `document` content blocks (base64, before the text, as the Messages API recommends) come with the rendered prompt as its `text` block. `ClaudeCode.input(prompt:attachments:)` builds it.
   - With browser access: `--mcp-config <file>` and `--allowedTools mcp__arx`. The file is written `0600` under the profile's `Turns` folder and removed when the turn ends. It runs the bundled `ArxMCP` with the profile's automation credential, so every tool call goes through Arx's own grant and approval checks.
4. `claude` receives only `HOME`, `PATH`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TMPDIR` and `SHELL`. `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, cloud-provider switches and Arx's own MCP variables never reach it.
5. `ClaudeCodeStream` maps the output, as documented in the [Agent SDK reference](https://code.claude.com/docs/en/agent-sdk/typescript):
   - `system`/`init` maps to `started`. If the `arx` server failed, the turn fails with `browserToolsUnavailable`.
   - Partial `text_delta` events map to `text`.
   - `tool_use` and `tool_result` map to tool activity.
   - `api_retry` maps to `retrying`, and `permission_denied` to `toolDenied`.
   - `rate_limit_event` maps to `usageWarning`. A rejection becomes `usageLimit`, or `usageCreditsRequired` for `credits_required`.
   - `result` maps to `completed`, or to a failure.
   - Output that ends without a `result` is `interrupted`. Unknown lines are skipped.

## Models

The model aliases `opus`, `sonnet`, `haiku` and `fable` come from the [CLI reference](https://code.claude.com/docs/en/cli-reference). Claude Code has no command that lists models. `nil` uses the person's default, and Anthropic decides which models a plan may use.

## Conversations

Claude Code keeps its own transcript of each session under `<configDirectory>/projects/<project>/<session>.jsonl`, where the configuration folder comes from `claude auth status`.

- Every message is its own `--print` run, and follow-ups use `--resume`. That's documented. A single long-lived process per chat (`--input-format stream-json`) is deferred, because the raw CLI input format and its interrupt request aren't documented.
- `--no-session-persistence` isn't used, because it rules out follow-ups. Ephemeral chats keep their transcript only while open, and `discard(_:)` deletes it when the chat expires, the browser quits, or a person deletes it.
- The working directory is per profile, so sessions from different profiles are stored in different project folders.

## Automated runs

`liveValue` is `.unavailable(.claude)` in tests, smokes and headless runs, and when `ARX_SKIP_AGENTS` is set (`AgentProviderClient.isEnabled`). `testValue` is unimplemented. Tests build `.claudeCode(_:)` over a temporary home and a fake `AgentProcessRunner`.

## Real-account check (run by a person)

With Claude Code installed and signed in:

1. Connect, then check that `account()` reports `signedIn`.
2. Pick a model.
3. Stream a reply.
4. Read the current page through the browser tools, and run a granted action.
5. Dismiss the UI and continue the conversation.
6. Cancel a turn.
7. Run `claude auth logout`, and check that the next turn fails with `signedOut`.
8. Hit a usage limit or an expired login, and check that the prompt is kept.
