# Chat wait-state and sources

Reference: ChatGPT chat UI, 7 Oct 2026. Behavior to steal. Do not copy their chrome, bubbles, or colors. Slate stays a solid page, 15pt body, one chat component set.

The user should never sit on a black box. While the model works they see what it is doing. When it is done they can open what it did. Claims that came from a source carry that source on the sentence.

## Sources on the claim

A source is a small chip in the text, at the end of the sentence it supports. Not a list under the reply. Not only inside “What ran.”

The chip is the source mark plus a short name. If more than one source backs that span, the chip says `+N` (`Paper +1`).

Hover opens a compact popover:

- Source mark and title
- Prev / next when there are several
- Count (`1/2`)
- Click the row to open the source (URL, note, decision, thread)

Do not dump raw ids. Use the title the tool already returned.

Until ChatGPT-as-provider exists, Cursor will not send citation annotations. Attach chips from the tools that just ran (note title, thread title, fetched URL). When Responses `url_citation` exists, use those too.

Persist the title and the URL (or the KB id). Do not save favicon files. Resolve the site icon at display time from the host, in memory. Offline or a failed fetch uses a generic mark.

## Tool row in the stream

While a tool is running, a single line sits in the transcript, in order, not in a pile at the bottom:

- The tool’s icon (Gmail logo in the reference; Slate: glasses for notes, globe for search, placeholder `C` for Cursor-as-source)
- A live title (`Searching Gmail…`, `Reading notes`)
- Optional chevron if there is more to open

When that tool finishes, the same line stays where it is and the verb goes past tense (`Searched Gmail for …`). Then the model may write, then another tool may run under that. Stack in time. Do not hoist every tool to the top.

## Work accordion

The top of the turn is one disclosure:

**While waiting (open):** label is `Thinking` (or the current live title). Body is the live log: thinking, tool rows, and any interim “here is what I have so far” text. The user watches this.

**When the turn ends (closed):** the label becomes `Worked for 38s`. The body is the same log. The final answer sits below, outside the accordion.

Time is wall clock from send to last token. Do not invent a vendor duration if we already have one.

The final answer is not hidden in the accordion. The accordion is how they waited. The answer is what they read.

## Order in one turn

1. User message
2. Work accordion opens (`Thinking`)
3. First tool row (icon + live title)
4. Interim text if the model speaks before it is done
5. Next tool row, more text, as they happen
6. Accordion closes and renames to `Worked for Ns`
7. Final answer, with source chips on the claims

## Not this

- The orb
- A checklist of `Listed notes` dumped above or below the reply
- “Writing…” / “Thinking…” with no tool or source
- Rebuilding ChatGPT’s message bubble, pill composer, or action bar

## Where it lives

`ChatMessages` draws it. `ChatRuntime` / the bridge keep the turn log and the clock. Do not add a second chat.

See also: [`chat-components.md`](chat-components.md).
