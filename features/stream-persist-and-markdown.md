# Streaming: don’t save or reparse on every token

Problem from 8 Oct 2026. Direction is locked.

Once tokens start, chat still feels slow because the main thread does too much per delta. The API is not the bottleneck.

## What’s wrong

Every token:

1. updates `ChatSession`
2. `persist()` writes the whole conversation to SwiftData (`onTick` on `objectWillChange`)
3. SwiftUI re-renders the live bubble
4. `AssistantMarkdown` reparses the **entire** assistant message and `setAttributedString`s it
5. a 60fps fade runs on the new characters
6. `Task.yield()` hops back to the main actor

The stream loops also run on `@MainActor`, so network handling, disk, and layout share one thread.

## What to do, in order

1. **Persist on a timer or on `.done`.** 400–500ms debounce, plus a final save. Not per token.
2. **Coalesce paints.** Buffer deltas, flush every 30–50ms. Drop `Task.yield()` per character.
3. **Take the stream off `@MainActor`.** Hop to main only to append text.
4. **Don’t rebuild the whole attributed string.** Append the new run. Reparse only the incomplete last block (open fence, half-written `**`).

## Libraries

Slate already has [AIChatKit](https://github.com/NerdSnipe-Inc/AIChatKit) (`ChatSession`, unused `MarkdownMessageView`) and [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui). Neither parses incrementally. MarkdownUI is maintenance-only; [discussion #261](https://github.com/gonzalezreal/swift-markdown-ui/discussions/261) is this exact problem.

[Microsoft SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown) is the library built for token streams (`StreamedMarkdownView`). Worth it *after* persist debounce. Switching the bubble to `MarkdownMessageView` alone will not feel fast.

Apple has no streaming-chat-markdown recipe. TextKit / `NSTextStorage` incremental edits are the documented piece.

## Do not

- Call `runtime.persist()` from `session.objectWillChange`
- Re-theme or replace the chat page to “fix” streaming
- Adopt MarkdownUI or `MarkdownMessageView` as the streaming fix

## Where it lives

`AppModel.chatRuntime` `onTick`, `ChatRuntime.persist`, `CursorChatProvider.stream` / `ChatGPTProvider.stream` (`@MainActor`, `Task.yield`), `AssistantMarkdown` / `AssistantMarkdownTextView.apply`.

See also: [`chat-components.md`](chat-components.md), [`chat-wait-state.md`](chat-wait-state.md).
