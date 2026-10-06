# ChatGPT / Claude import

Plan from 6 Oct 2026. Direction below is locked. UI is not.

Web ChatGPT and web Claude can look at Slate and change Slate. The user does not need those desktop apps. There is no Slate account.

Cursor already does this on the Mac through `slate-mcp`. This is the same tools, reached from the browser.

If the chat cannot look at Slate, it does not know your projects or what you already have. Then everything has to land in a dump pile. That is not this feature.

## What the user does

1. In Slate they **create a key**. Default life is 7 days. They can set any life up to 180 days.
2. Slate shows a URL and the key. They paste both into ChatGPT or Claude when adding Slate as an MCP.
3. Slate stays open.
4. The chat lists projects, reads notes, saves or updates. It hits the app now.

Creating a key is not an account. One key at a time. Creating a new one expires the old one.

When they need a new key: the old one ran out, or they expired it on purpose. They paste the new one into ChatGPT / Claude.

## Key

Slate makes the key and keeps it in the keychain. It tells the Worker the hash and when it dies. ChatGPT / Claude send the real key. The Worker never stores the real key.

One key at a time.

- Create a new key → old key dies → Worker drops the old connection.
- The clock runs out → same.
- Expire on purpose is the same as the clock running out.

## How a call works

Slate, while open and while the key is good, stays connected to the Worker.

ChatGPT or Claude calls the Worker. The Worker hands the call to Slate. Slate reads or writes the same database the windows use.

The tools are the ones `slate-mcp` already has: list / get / create / update on projects, decisions, threads, notes.

If Slate is closed or the key is dead, the call fails. The chat can say Slate is not reachable. Do not store the message in the cloud to try later. Do not build a waiting status.

The Worker does not keep notes.

## Where something lands

The chat looks up the project and passes that id. Same as Cursor. If it skips the lookup, it files in the wrong place. That is the chat being lazy, not a Settings default pile.

Do not create a project from a guessed name. Create a project only if the user asked for one.

## Worker

| Call | Who | What |
| --- | --- | --- |
| `POST /keys` | Slate | Hash + expiry. If a key was already live, expire it and disconnect. |
| Socket | Slate | Connect under the live key. |
| `POST /mcp` | ChatGPT / Claude | Hand the tool to Slate. |

No extra store. No “got it” callback.

## Do not

- Require Claude Desktop or ChatGPT Desktop.
- Create Slate accounts.
- Let two keys stay live.
- Hold writes because Slate is closed.
- Make this send-only.
- Show a waiting / pending state for this.
- Replace Cursor’s local MCP with this. Same tools, different way in.
