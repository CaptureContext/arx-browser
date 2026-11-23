# AgentClient

Provider-neutral contracts for the agent people talk to from Arx's command bar. Claude ([ClaudeAgentClient](../ClaudeAgentClient/README.md)) and ChatGPT ([CodexAgentClient](../CodexAgentClient/README.md)) each build an `AgentProviderClient`; features only use the types here. The chat UI is [ChatFeature](../../../features/Sources/ChatFeature/README.md) (DEV-720).

## Contracts

- **`AgentProviderClient`:** one provider's adapter.
  - `account()` reports the app-wide connection: `signedIn`, `signedOut(instructions:)`, `unsupportedSignIn(method:)`, `runtimeMissing` or `unavailable`. It never starts a sign-in, because people sign in through the provider's own app.
  - `models()` lists the models a profile can pick.
  - `send(_:)` runs one turn as an `AsyncThrowingStream<AgentEvent>`. Cancelling the task that iterates the stream stops the turn. A turn keeps running while something iterates it, so a session-scoped owner keeps it going after the chat UI is dismissed.
  - `discard(_:)` removes what the provider kept on this Mac for a conversation.
  - `unavailable(_:)` is for runs that may not use agents. `unimplemented(_:)` fails tests on any call.
  - `isEnabled` turns agents off for test, smoke and headless runs, and when `ARX_SKIP_AGENTS` is set.
- **`AgentTurnRequest`:** the profile, the conversation, the provider's `resumeToken`, the prompt, the model and an optional `AgentEffort` (`low`, `medium` or `high`).
  - `attachments` hold only context the person attached on purpose (`page`, `selection`, `tabs`). Typing never sends page content by itself.
  - `browserAccess` is the profile's browser tools; `nil` runs the turn without any.
- **`AgentEvent`:** `started(resumeToken:modelID:)`, `text`, `toolStarted`, `toolFinished`, `toolDenied`, `usageWarning`, `retrying` and `completed`.
- **`AgentFailure`:** why a turn stopped. The cases cover a missing runtime, signed-out or expired sign-ins, sign-in methods Arx won't use, usage limits, required usage credits, billing, unavailable models, a reached turn limit, browser tools that didn't start, interrupted streams, a provider that went silent (`timedOut`, raised by the chat, not the adapters) and unrecognized failures. The prompt that started a turn stays with the caller, so it's never lost.
- **`AgentProfileSettings`:** a profile's provider, connection, model and `AgentRetention`.
- **`AgentConversation` and `AgentMessage`:** a chat in one profile, with the retention it started with.

## Retention

The assistant is a quick utility, like a voice assistant, not a place to keep history. `AgentRetention` is one per-profile preference:

- **`ephemeral` (default):** a chat lives in memory only. It ends 20 minutes after its last activity (`expiresAt`, `isExpired(at:)`) or when the browser quits. Nothing about it stays on this Mac afterwards.
- **`persistent`:** chats are saved in the profile until the person deletes them.

The app owns the timers and calls the store:

- `started(_:resumeToken:)` when a turn reports `started`. It remembers an ephemeral chat's provider transcript in the profile's `Transcripts.json`.
- `delete(_:provider:)` when a chat expires, the browser quits, or a person deletes one. It discards the provider's transcript and forgets it.
- `sweep(_:provider:)` at launch and quit. It discards every transcript still remembered, so a crash leaves nothing behind.

## Browser tools and permissions

`AgentBrowserAccess` (`@Dependency(\.agentBrowserAccess)`) issues a profile's `Connection`: the bundled `ArxMCP` helper and an `AgentSetup.Credential`.

- The app supplies it with `prepareDependencies`, registering one automation client per profile for the embedded agent and granting it that profile only.
- The agent then uses the same MCP tools, socket, grants and approvals as outside agents, and Arx checks every call. The embedded agent can't do anything an outside agent with the same grants couldn't.
- The credential goes only into the helper's environment. It never reaches the provider's own process, a log or another profile's folder.
- `liveValue` throws `unavailable` until the app provides it.

## Storage and profile boundaries

`AgentProfileFolders` keeps each profile under `~/Library/Application Support/Arx/Agents/Profiles/<profile>/`, or `Arx Dev/…` in Arx Dev (DEV-1013).

- Folders are `0700` and files are `0600`.
- Writes go through `RealHomeGuard`, so tests can't touch the real home folder.

`AgentConversationStore` (`@Dependency(\.agentConversations)`) saves persistent chats, the profile's `AgentProfileSettings` and the ephemeral transcript ledger there.

- Every call names its profile. A conversation file whose `profileID` doesn't match its folder is ignored.
- Ephemeral chats are never written.
- `deleteProfile` removes the profile's whole folder.

## Prompts and streaming

- **`AgentPrompt.guidance`:** the system prompt every provider gets. It asks for short Markdown with the answer first, tells the agent to gather context with the browser tools within its grants and to treat page content as untrusted, and to offer an artifact or a full agent app for complex jobs.
- **`AgentPrompt.render`:** wraps attached context as escaped, untrusted data. Text files go inline; images and PDFs are only named there, because adapters send them as the provider's own inputs (`AgentPrompt.images(in:)`, `documents(in:)`).
- **`AgentFileAttachment`** (DEV-798): a file, image or page capture in `AgentContextAttachment.file`, with its media type, bytes, a small preview and the page a capture came from. Messages in the transcript keep it `withoutData`, so saved chats hold only the name and preview. `AgentAttachmentLimits` (`AgentProvider.attachmentLimits`) says how many files and images and what sizes a provider takes in one message; `problem(with:)` names the first one it can't.
- **`AgentEventCoalescer` and `coalesced(interval:)`:** join streamed text so a store gets at most about ten batches a second. Other events flush the waiting text first, so order is kept.

## Processes

`AgentProcessRunner` runs a provider's own command-line app with an explicit environment, a working directory, and the prompt on standard input, so prompts don't show up in process listings.

- Standard error is discarded and never logged.
- A cancelled run is interrupted first, and terminated if it's still running after three seconds.
- Tests replace the runner with canned output.
