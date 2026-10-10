# Chat components

Membrae has multiple conversations, but one implementation of the chat interface. Reuse these components instead of building a Home, project, or track-specific version.

## Components

### `ChatInput`

The shared input used everywhere.

It contains:

- model picker
- usage
- send or stop button
- error message
- completed-change status

It does not create, select, or persist a conversation, and it does not own the unsent draft. The caller supplies the text binding, the model binding, and the send and stop actions. This lets the same input start a new conversation on Home or Overview and send directly to an existing conversation elsewhere.

`ChatInput` owns its internal appearance. The screen that places it owns only its outer width, padding, separator, and position.

### `ChatMessages`

The shared conversation history.

It renders user messages, assistant responses, the work control (live title or past `Worked for Ns`), source chips, object cards, errors, and message actions. Wait-state, sources, and object cards are specified in [`chat-wait-state.md`](chat-wait-state.md). It reads entries from one `ChatSession` plus the current turn on `ChatRuntime`.

It does not send messages, create conversations, or persist history.

### `ConversationChat`

The complete interface for one existing conversation.

It gets that conversation's `ChatRuntime`, then places:

1. `ChatTitleBar` when the chat is a project conversation in the regular layout
2. `ChatMessages`
3. `ChatInput`

It also connects the input to that runtime's draft, send, stop, model, error, and change state.

### `ChatRuntime`

The state and persistence for one conversation.

Every `Conversation.id` gets a separate `ChatRuntime` through `AppModel.chatRuntime(for:project:)`. Each runtime has its own:

- `ChatSession`
- history
- selected model
- unsent draft
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
- **Ask Membrae:** `ThreadChatPane` resolves a conversation attached to the selected track, then displays `ConversationChat` in compact layout.
- **Chats:** workspace page. Running conversations first. If none are running, “Nothing running.” then the 10 most recent sessions. A row opens that conversation. The sidebar icon spins while any turn is generating.

The queued first message includes its destination conversation ID. Only the matching runtime consumes it.

## Layout ownership

The shared components own chat content and controls. Their parent screens own placement:

- Home: 32 horizontal, 14 vertical
- Overview and empty project chat: maximum width 680, 32 horizontal, 14 vertical, separator above
- Regular conversation: 32 horizontal, 14 vertical
- Ask Membrae: 16 horizontal, 14 vertical

Do not put page navigation, project selection, track selection, or screen-specific padding inside `ChatInput` or `ChatMessages`.

## Adding chat features

- Input controls such as attachments, voice, or new send actions go in `ChatInput`.
- Message rendering and message actions go in `ChatMessages`.
- Conversation lifecycle and persistence go in `ChatRuntime`.
- Screen-specific navigation stays in the screen that hosts the chat.

Do not add another chat text field directly to Home, Overview, project chat, or Ask Membrae.

Chat slowness is not one ticket. Each problem has its own spec:

- [`code-roots-on-demand.md`](code-roots-on-demand.md)
- [`hot-cursor-runner.md`](hot-cursor-runner.md)
- [`chatgpt-lazy-prep.md`](chatgpt-lazy-prep.md)
- [`worker-as-tool.md`](worker-as-tool.md)
- [`provider-turn-context.md`](provider-turn-context.md)
- [`stream-persist-and-markdown.md`](stream-persist-and-markdown.md)
