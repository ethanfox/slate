# ChatGPT sign-in + Cursor as a source

Plan from 30 Sep 2026. Not implemented.

Sign in with ChatGPT lets a user bring their Plus/Pro plan into Membrae. It does **not** bring ChatGPT memory, chats, custom instructions, or files. Membrae stays the personal context.

Today every Membrae chat is a Cursor agent. The model picker is Cursor’s list. Membrae MCP rides on that agent. Picking a GPT model still goes through Cursor and spends Cursor quota.

## Goals

- User can sign in with ChatGPT and use their plan for chat.
- Provider and source are separate.
  - **Provider:** who writes the reply and who pays (ChatGPT or Cursor).
  - **Source:** what that model can call (Membrae KB, Cursor on a repo, …).
- If both are connected and GPT is primary, Cursor stays available as a repo source. It is not also the chatbot.
- ChatGPT never sees the Cursor key. Membrae is the glue.

## What ChatGPT actually gives us

Two permissions, separately:

1. Identity: name, email, profile picture.
2. Plan usage: eligible Responses API calls billed to the user’s ChatGPT plan.

Logging in does not turn on plan usage. Plan usage does not grant conversations or memory.

Membrae is a local Mac app, so it fits OpenAI’s open-source / local path: no partner approval, no API key, no client secret. Paid or hosted products need the partner waitlist.

## Shape

```
User
  └─ Membrae chat
       ├─ Primary: ChatGPT    billed to ChatGPT plan
       │     tools: Membrae KB, ask_cursor, …
       └─ Primary: Cursor     current path
             tools: Membrae MCP (already wired)
```

Do not make the two connections fight over the composer. After ChatGPT sign-in exists, do not silently route GPT models through Cursor.

## Sign-in (moderate)

OpenAI’s local flow:

1. Generate and persist a host ID once.
2. Open the system browser (PKCE, `dynamic_agent_client`).
3. User approves “use my ChatGPT plan.”
4. Store tokens in the keychain.
5. Call the Responses API with that token.

Settings should look like the Cursor page: Continue with ChatGPT, connected email, “Using ChatGPT plan,” Manage usage.

Official SDK is JS (`@siwc/local`). Membrae is Swift, so either reimplement OAuth in Swift or wrap the Node SDK in the existing runner.

A working sign-in plus streamed replies is a few days. Polished settings, refresh, and usage errors is more like a week. That only gets a chatbot. GPT cannot save decisions or read the knowledge base until it has tools.

## Cursor as a source for GPT

There is no official “ChatGPT uses Cursor.” Membrae owns the tool.

When GPT needs repo context:

1. GPT emits `ask_cursor`.
2. Membrae starts a **separate** Cursor run with the user’s existing Cursor API key.
3. Membrae returns the result to GPT.

Uses the user’s Cursor account, plan, and usage. The chat reply still spends ChatGPT quota. Two bills for one question.

Cursor can walk the repo if we point it at the **actual checkout** (or a GitHub repo for cloud agents). Today Membrae’s Cursor cwd is the knowledge-base Agent folder, not a git repo.

**Why Cursor instead of GPT walking files itself:** Cursor’s ask/search harness and any existing index on that repo. Worth it for “how does this work.” Not worth it for one known file.

Do not MCP ChatGPT into Cursor. Cursor has no clean “query my indexed repos” MCP for another model. `membrae-mcp` is the knowledge base, not repos. A Membrae-owned `ask_cursor` tool is the path.

## Force cheap + Ask on lookups

The lookup run does not inherit the chat model or the current Membrae chat runner.

| Setting | Lookup run | Current Membrae chat |
| --- | --- | --- |
| Model | Composer (or cheapest listed Cursor model) | User’s chat model |
| Mode | Ask (read-only) | Agent (writes KB) |
| cwd | Project repo | Agent folder + Membrae MCP |
| Tools | Search / read only | Membrae MCP writes allowed |

Ask, not Plan or Agent. Ask walks the repo and answers. Plan wants to design a change. Agent can edit.

Membrae talks to `@cursor/sdk` (`Agent.create`), which is Agent by default. The CLI has `--mode=ask`. The SDK does not expose that as cleanly, so enforce Ask ourselves:

- No write / edit tools
- No mutating shell
- No Membrae save tools on that run
- Prompt: search, read, answer, stop

Do not reuse the current chat runner as-is for lookups.

## GPT also needs Membrae tools

Take the existing Membrae MCP tools and expose them to GPT as Responses function tools. Then GPT can read and write the knowledge base the way Cursor can. Without that, GPT is a chat box on a prompt dump. ContextBuilder still injects project context either way.

## Out of scope / do not do

- Expect ChatGPT memory or personal context to arrive with sign-in.
- Wire ChatGPT → Cursor MCP.
- Use Plan mode for repo questions.
- Let a lookup Cursor run edit the repo or the knowledge base.
- Ship this as a paid hosted product on the local SIWC path.

## Likely build order

1. Continue with ChatGPT + Responses streaming (no tools).
2. Provider switch in the model picker (ChatGPT vs Cursor).
3. Same Membrae tools on GPT.
4. `ask_cursor`: Composer + Ask-style, pointed at the project repo.
