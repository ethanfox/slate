# Keep the Cursor runner hot

Problem from 8 Oct 2026. Direction is locked.

The Cursor runner is one-shot. Every send spawns Node, starts `membrae-mcp`, lists tools, then `Agent.create` or `Agent.resume`. The process exits when the turn ends. `externalSessionID` only skips creating a *new* agent. It does not keep the process warm.

That is several seconds of dead air after send, even on a local folder.

## What to do

Keep one runner process per conversation (or one process with a conversation id on each request):

- stdin is a JSON-RPC loop, not a single request
- keep the Agent and the MCP child alive across turns
- idle-kill after 5–10 minutes, or when the conversation closes
- one live agent per conversation; the existing `agent_busy` path stays

## Do not

- Spawn `membrae-node` + `runner.mjs` on every `stream`
- Call `agent.close()` and `process.exit` at the end of a successful turn
- Use one shared Agent for two conversations

## Where it lives

`CursorConversationBridge.run`, `PersonalContextRunner/runner.ts` `main()`. `process` on the bridge is already stored and torn down in `finished()`.

See also: [`chatgpt-lazy-prep.md`](chatgpt-lazy-prep.md), [`code-roots-on-demand.md`](code-roots-on-demand.md).
