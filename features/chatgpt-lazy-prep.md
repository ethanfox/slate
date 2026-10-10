# ChatGPT: don’t prep the world before the first token

Problem from 8 Oct 2026. Direction is locked.

ChatGPT has no Node agent to keep warm. The delay is work Membrae does *before* `URLSession.bytes`: validate the session, `prepareCodeRoots()`, spawn `membrae-mcp` just to list tools, then POST. If the model calls tools, rounds stay sequential. That is the API. Paying clone + process spawn on “what did we decide” is not. After the tool budget, force an answer — see [`chatgpt-tool-budget.md`](chatgpt-tool-budget.md).

## What to do

| Every send | Once, or on demand |
|---|---|
| POST `/v1/responses` | `tools/list` (cache on the bridge) |
| | One long-lived MCP process for the chat |
| | `prepareCodeRoots()` when a `project_*` tool actually runs |
| | Token refresh (skipped if more than 60s left; retry on `token_expired` — see [`chatgpt-token-refresh.md`](chatgpt-token-refresh.md)) |

Tool-call rounds stay sequential. That is the API. First token should not wait on a repo or a fresh MCP child.

## Do not

- Spawn MCP on every send to rediscover the same Membrae tools
- Call `prepareCodeRoots()` in `ChatGPTProvider.stream` before the request
- Refresh the ChatGPT session when it is still valid

## Where it lives

`ChatGPTProvider.stream`, `MembraeToolGateway.definitions` / `invokeMCP`, `ChatGPTSignIn.validSession`.

See also: [`code-roots-on-demand.md`](code-roots-on-demand.md), [`provider-turn-context.md`](provider-turn-context.md), [`hot-cursor-runner.md`](hot-cursor-runner.md).
