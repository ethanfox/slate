# Chat components

Slate has multiple conversations, but one implementation of the chat interface. Reuse these components instead of building a Home, project, or track-specific version.

## Components

### `ChatInput`

The shared input used everywhere.

It contains:

- model picker
- usage
- draft text
- send or stop button
- error message
- completed-change status

It does not create, select, or persist a conversation. The caller supplies the model binding and the send and stop actions. This lets the same input start a new conversation on Home or Overview and send directly to an existing conversation elsewhere.

`ChatInput` owns its internal appearance. The screen that places it owns only its outer width, padding, separator, and position.

### `ChatMessages`

The shared conversation history.

It renders user messages, assistant responses, the work accordion, tool rows in time order, source chips, object cards, errors, and message actions. Wait-state, sources, and object cards are specified in [`chat-wait-state.md`](chat-wait-state.md). It reads entries from one `ChatSession` plus the current turn on `ChatRuntime`.

It does not send messages, create conversations, or persist history.

### `ConversationChat`

The complete interface for one existing conversation.

It gets that conversation's `ChatRuntime`, then places:

1. `ChatMessages`
2. `ChatInput`

It also connects the input to that runtime's send, stop, model, error, and change state.

### `ChatRuntime`

The state and persistence for one conversation.

Every `Conversation.id` gets a separate `ChatRuntime` through `AppModel.chatRuntime(for:project:)`. Each runtime has its own:

- `ChatSession`
- history
- selected model
- generation and cancellation state
- errors
- tool bridge
- persistence

Sharing the components does not share conversation state.

## Where they are used

- **Home:** `ChatInput` creates a new conversation without a project and queues its first message.
- **Project Overview:** `ChatInput` creates a new conversation attached to that project and queues its first message.
- **Empty project chat:** `ChatInput` creates a new conversation attached to that project.
- **Existing project chat:** `ConversationChat` displays and continues the selected conversation.
- **Ask Slate:** `ThreadChatPane` resolves a conversation attached to the selected track, then displays `ConversationChat` in compact layout.

The queued first message includes its destination conversation ID. Only the matching runtime consumes it.

## Layout ownership

The shared components own chat content and controls. Their parent screens own placement:

- Home: 32 horizontal, 14 vertical
- Overview and empty project chat: maximum width 680, 32 horizontal, 14 vertical, separator above
- Regular conversation: 32 horizontal, 14 vertical
- Ask Slate: 16 horizontal, 14 vertical

Do not put page navigation, project selection, track selection, or screen-specific padding inside `ChatInput` or `ChatMessages`.

## Adding chat features

- Input controls such as attachments, voice, or new send actions go in `ChatInput`.
- Message rendering and message actions go in `ChatMessages`.
- Conversation lifecycle and persistence go in `ChatRuntime`.
- Screen-specific navigation stays in the screen that hosts the chat.

Do not add another chat text field directly to Home, Overview, project chat, or Ask Slate.
