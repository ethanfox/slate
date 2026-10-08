# ChatGPT: force an answer, don’t throw

Problem from 8 Oct 2026. Direction is locked.

ChatGPT is `store: false`. After identity-only context it lists and gets records one round at a time. Eight sequential rounds later Slate threw “exceeded the tool-call limit” and the user got nothing.

## What to do

- Eight tool rounds, then one more request with no tools.
- After the last tool outputs, tell it to answer from what it already has.
- Never throw because it wanted another lookup.

The opening prompt already says: fetch only this message, batch calls, do not walk the whole project.

## Do not

- Fail the turn when the budget is used
- Raise the cap so it can wander longer
- Dump `ContextBuilder.package` again to avoid tools

## Where it lives

`ChatGPTProvider.stream` / `toolsForRound` / `inferenceBody`. Opening line in `ContextBuilder.prompt`.

See also: [`chatgpt-lazy-prep.md`](chatgpt-lazy-prep.md), [`provider-turn-context.md`](provider-turn-context.md).
