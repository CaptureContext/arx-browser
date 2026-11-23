# CodexAgentClient

ChatGPT for Arx's agent, through the person's own Codex CLI (`@Dependency(\.codexAgent)`, an `AgentProviderClient` from [AgentClient](../AgentClient/README.md)). It mirrors [ClaudeAgentClient](../ClaudeAgentClient/README.md).

## Why the Codex CLI

Checked against OpenAI's docs and the `openai/codex` source (tag `rust-v0.166.0`) on 8 November 2026. The findings are in DEV-643.

- `codex exec` reuses the CLI's saved sign-in ([Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)). With a ChatGPT sign-in, usage counts against the person's ChatGPT plan. With an API key, it's billed at API rates ([Authentication](https://learn.chatgpt.com/docs/auth)).
- Arx never signs anyone in and never reads a credential. The person runs `codex login`, and Codex keeps the login in `~/.codex`.
- OpenAI doesn't explicitly allow or forbid a third-party app running the person's own CLI. Its documented route for apps billed to a ChatGPT plan is [Sign in with ChatGPT token sharing](https://developers.openai.com/siwc/token-sharing-open-source), for apps that hold their own tokens. Ask OpenAI before the public release.
- After the plan's included limits, Codex may continue on purchased credits ([Pricing](https://learn.chatgpt.com/docs/pricing)). The UI should say that chats count against the person's ChatGPT plan.

## How a turn runs

1. Find `codex` in `~/.local/bin`, `/opt/homebrew/bin` or `/usr/local/bin`.
2. Run `codex login status` before every turn, through `/bin/sh` because it prints to standard error. Only `Logged in using ChatGPT` is used. An API key, access token, Bedrock or workload identity is reported as `unsupportedSignIn` instead of being used.
3. Make a private folder for the turn under the profile's `Turns` folder and use it as the working directory. Remove it when the turn ends.
4. With browser access, write `.codex/config.toml` into that folder with mode `0600`. It runs the bundled `ArxMCP` with the profile's automation credential in the helper's own environment, so every tool call goes through Arx's own grant and approval checks. It also sets:
   - `omit_tools_from = ["deferred", "code_mode"]`, which lists Arx's tools directly under `mcp__arx`;
   - `default_tools_approval_mode = "approve"`, because under `approval_policy = "never"` Codex would otherwise refuse every tool that isn't marked read-only.
5. Start `codex exec --json` with the prompt on standard input (`-`), or `codex exec resume <thread> -` to continue a chat:
   - `--ignore-user-config` and `--ignore-rules`: the person's own `config.toml`, with its MCP servers, hooks and features, stays out. The sign-in still comes from `~/.codex`.
   - `--disable` for `shell_tool`, `unified_exec`, `view_image`, `image_generation`, `multi_agent`, `goals`, `apps`, `plugins`, `hooks` and `memories`.
   - `-c` with:
     - `sandbox_mode="read-only"` and `approval_policy="never"`;
     - `web_search="disabled"` and `tools.experimental_request_user_input.enabled=false`;
     - `skills.include_instructions=false` and `skills.bundled.enabled=false`;
     - `project_root_markers=[]`;
     - `model_reasoning_effort` from the request, `low` by default;
     - `developer_instructions` with `AgentPrompt.guidance`;
     - with browser access, `projects={"<turn folder>"={trust_level="trusted"}}`, because Codex reads a folder's `.codex/config.toml` only when the folder is trusted.
   - `--model <slug>` when the profile picked one.
   - `--image <file>` for each attached image, first, since `exec`'s `--image` takes several values and the next flag ends them (DEV-798). The images are written `0600` to `Attachments/` in the turn's folder and removed with it. Codex takes no documents, so `CodexCLI.readable` turns a PDF into its text (PDFKit) before the prompt is rendered.
6. `codex` receives only `HOME`, `PATH`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TMPDIR` and `SHELL`. These never reach it:
   - `CODEX_API_KEY`, which would override the ChatGPT sign-in;
   - `OPENAI_API_KEY`, `CODEX_ACCESS_TOKEN`, `CODEX_HOME`, `OPENAI_ORGANIZATION`;
   - Arx's own MCP variables.
7. `CodexStream` maps the JSONL output:
   - `thread.started` maps to `started`, with the thread as the resume token.
   - `agent_message` maps to `text`. Codex reports whole messages, not text as it's written, so its models don't claim the `streaming` capability.
   - `mcp_tool_call` maps to tool activity. A call Codex refused for approval also maps to `toolDenied`.
   - `file_change`, `command_execution` and `web_search` map to `toolDenied`. They can't happen with the settings above.
   - `Reconnecting... N/M (reason)` errors map to `retrying`.
   - `turn.completed` maps to `completed`.
   - `turn.failed` maps to a failure: usage limits, credits or quota, signed-out or expired sign-ins, and unknown models are recognized, and anything else is `runtimeFailed` with the text.
   - A `codex` that can't be started is `runtimeMissing`, for the sign-in check and for the turn.
   - Output that ends before the turn finishes is `interrupted`. When browser tools were requested and no thread started, it's `browserToolsUnavailable`: Codex stops before starting a thread when the `arx` server fails, and says why only on standard error.
8. Codex has no turn cap. The adapter stops the turn when the agent starts a 13th browser tool call (`CodexCLI.maxTurns` is 12), and the turn fails with `turnLimitReached`.

### What can't be switched off

- **`apply_patch`.** Codex's model catalog declares it, and no setting removes it. The read-only sandbox refuses every patch before it touches disk ("patch rejected: writing is blocked by read-only sandbox"). The only way to remove it is a custom model catalog, which would replace OpenAI's model metadata.
- **`list_mcp_resources`, `list_mcp_resource_templates` and `read_mcp_resource`.** Codex adds them whenever an MCP server is configured. They reach only Arx's server.
- **`~/.codex/AGENTS.md`.** Codex always loads it. It's the person's own instruction text and can't add tools.
- **Keychain sign-ins.** `--ignore-user-config` also ignores `cli_auth_credentials_store`, so Codex reads the default `~/.codex/auth.json`. If the person chose keychain storage in their own config, `codex login status` says signed in but turns fail with an expired or missing sign-in.

### Checked with Codex 0.167.1 (DEV-643, 11 November 2026)

Arx's exact arguments, the resume form and the per-turn trusted `.codex/config.toml` all still work with 0.167.1, against a local Responses server and a throwaway `CODEX_HOME`. Two things changed:

- **Codex 0.167 couldn't finish the handshake with Arx's `ArxMCP`.** Its `initialize` announces `capabilities.experimental` as an object (`"codex/auth-change": {}`). The MCP Swift SDK 0.12.1 reads those values only as strings, so the helper answered with a decoding error. Arx's server is `required`, so Codex quit before starting a thread, with the reason only on standard error. Arx reported `browserToolsUnavailable`, but the chat hid the failure (see ChatFeature). [BrowserMCPServer](../BrowserMCPServer/README.md) now drops those capabilities before the SDK reads them.
- When it can't reach the network, Codex now prints `Reconnecting... waiting for network (…)`, with no attempt count, and waits without a limit. The adapter treats it as the turn's last error. The chat stops waiting after three minutes of silence (`AgentFailure.timedOut`).

`CodexAgentTests` replays the recorded 0.167.1 output for an answer and for a turn without a sign-in.

## Models

`codex debug models` prints the catalog Codex itself picks from, refreshed for the signed-in plan. Models with `visibility` `list` are offered, in Codex's `priority` order. It's a debugging command, so when it fails, `models()` is empty and the turn uses Codex's default. A model the plan can't use fails the turn with `modelUnavailable`.

## Conversations

Codex keeps each thread in `~/.codex/sessions/YYYY/MM/DD/rollout-…-<thread>.jsonl`, with rows in its SQLite state.

- Every message is its own `codex exec` run, and follow-ups use `codex exec resume <thread>`, which works from any folder.
- `--ephemeral` isn't used, because it rules out follow-ups. `discard(_:)` runs `codex delete --force <thread>`. That removes the transcript and its rows when an ephemeral chat expires, the browser quits, or a person deletes a chat. A thread that's already gone counts as deleted.
- Tokens that aren't thread identifiers are ignored, so nothing else reaches the command.

## Automated runs

`liveValue` is `.unavailable(.openAI)` in tests, smokes and headless runs, and when `ARX_SKIP_AGENTS` is set (`AgentProviderClient.isEnabled`). `testValue` is unimplemented. Tests build `.codex(_:)` over a temporary home and a fake `AgentProcessRunner`.

## Real-account check (run by a person)

You need the Codex CLI installed (`codex --version`) and signed in with ChatGPT (`codex login`; `codex login status` prints `Logged in using ChatGPT`).

1. Connect, then check that `account()` reports `signedIn`.
2. Check that `models()` lists the plan's models, then pick one.
3. Send a prompt and check that the reply arrives.
4. Grant the embedded agent access to the profile. Read the current page through the browser tools, then run a granted action.
5. Dismiss the UI and continue the conversation. Check that the follow-up resumes the same thread.
6. Cancel a turn while a tool call is running.
7. Delete an ephemeral chat. Check that its `rollout-…-<thread>.jsonl` is gone from `~/.codex/sessions`.
8. Run `codex logout`, and check that `account()` reports `signedOut` and the next turn fails with `signedOut`.
9. Run `printenv OPENAI_API_KEY | codex login --with-api-key` with a test key. Check that `account()` reports `unsupportedSignIn(api_key)` and that no turn runs. Sign in with ChatGPT again afterwards.
10. Hit a usage limit or an expired login, and check that the prompt is kept.
