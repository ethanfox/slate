# Chat wait-state and sources

Reference: ChatGPT chat UI, 7 Oct 2026. Behavior to steal. Do not copy their chrome, bubbles, or colors. Membrae stays a solid page, 15pt body, one chat component set.

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

## Object cards

When the model points the user at a note, track, decision, or other Membrae object, it writes a markdown link with a `membrae://` URL on its own line:

`[Title](membrae://note/UUID)`

That renders as a card in the reply. Click opens the object. Source chips stay for citations on a claim. Cards are for destinations. Do not dump raw ids.

Persist the title and the URL (or the KB id). Do not save favicon files. Resolve the site icon at display time from the host, in memory. Offline or a failed fetch uses a generic mark.

## Work control (one component, two states)

`WorkAccordion` in `ChatMessages` is the only wait-state control. Use it for the live turn and for past replies. Do not add a second view.

**Active (generating):** header stays `Thinking` (`Starting` only before the first event). One tool line sits under it and changes as the current tool changes. Do not grow a list. Do not replace the Thinking label. No chevron while live.

**Past (closed):** `Worked for 38s` (`Worked` if the clock is 0). Chevron if there is a tool list or thinking. This is history, not the live wait. Keep this look.

**Past (open):** the same control. Body is thinking (if any) plus the tool rows (icon + title + optional detail). Answer stays below, outside the control.

Time is wall clock from send to last token. Do not invent a vendor duration if we already have one.

The final answer is not hidden in the accordion. The accordion is how they waited. The answer is what they read.

## Order in one turn

1. User message
2. Work control shows `Thinking` (or Starting)
3. One tool line under Thinking updates as the current tool changes
4. Interim text if the model speaks before it is done
5. Control closes and renames to `Worked for Ns`
6. Final answer, with source chips on the claims
7. Chevron opens the tool list on that past control

## Not this

- The orb
- A checklist of `Listed notes` dumped in the live stream
- A second wait-state component for live vs past
- “Writing…” / “Thinking…” with no tool or source
- Rebuilding ChatGPT’s message bubble, pill composer, or action bar

## Where it lives

`ChatMessages` draws it. `ChatRuntime` / the bridge keep the turn log and the clock. Do not add a second chat.

See also: [`chat-components.md`](chat-components.md).
