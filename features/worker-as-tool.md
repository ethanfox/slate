# Worker is a tool, not a pre-roll

Problem from 8 Oct 2026. Direction is locked.

If a project has a worker, `ProjectWorkerChatProvider` runs a full code consult first, waits for it to finish, then starts the real chat. First token is delayed by an entire second model pass. Most messages never needed the repo.

The main model talks. If it needs a checkout, it calls a tool.

## What to do

- Chat stays the chat provider the user picked.
- Expose something like `consult_code` / `ask_worker`. The model passes a brief.
- That tool prepares roots (see [`code-roots-on-demand.md`](code-roots-on-demand.md)), runs the worker, returns findings.
- No worker call if the user asked about a decision, a track, or a note.

This matches [`workers-and-agent-board.md`](workers-and-agent-board.md): coding agents are workers you dispatch. They are not a hidden prefix on every Membrae turn.

## Do not

- Auto-consult because `workerProviderID` is set
- Wrap every project chat in `ProjectWorkerChatProvider`
- Stuff a full worker transcript into the next prompt unless the model asked for it

## Where it lives

`ProjectWorkerChatProvider.consult`, `ChatRuntime.makeSession` (the `workerProviderID` branch). Board / run objects stay in the workers spec.

See also: [`workers-and-agent-board.md`](workers-and-agent-board.md), [`code-roots-on-demand.md`](code-roots-on-demand.md).
