# Same turn context on every provider

Problem from 8 Oct 2026. Direction is locked.

Cursor and ChatGPT do not send the same project context. That is not a product difference. It is two memory models, and ChatGPT took the wasteful one.

## What’s wrong

**Cursor** has a live agent (`externalSessionID`). The opening turn sends `ContextBuilder.package` (decisions, tracks, notes). Later turns send `identity` only. The agent already has the rest.

**ChatGPT** is `store: false`. Stateless. `prepareProviderTurn` always does `opening: true` plus the full package, then also resends the whole transcript as `input`. Every “hi” pays the same 2–4k prefix.

## What to do

They should match:

- First turn: short identity + “use the Slate tools.”
- Later turns: identity only, or nothing new.
- Records come from MCP when needed, not from a dump on every request.

Do not put `ContextBuilder.package` in ChatGPT instructions on turn 2+.

## Do not

- Keep `prepareProviderTurn` on `opening: true` forever
- Add more project text to make up for a missing agent session
- Send the package “just in case” the model might mention a decision

## Where it lives

`CursorConversationBridge.prepare` vs `prepareProviderTurn`. `ContextBuilder.package` / `identity` / `prompt`. ChatGPT `instructions` + `input` in `ChatGPTProvider`.

See also: [`chatgpt-lazy-prep.md`](chatgpt-lazy-prep.md), [`code-roots-on-demand.md`](code-roots-on-demand.md).
