# ChatGPT and Claude import

Governing track: General MCP import. That body supersedes this file where they conflict (Durable Object routing, mcp.membrae.com, Gemini CLI, ChatGPT OAuth hold, separate import worker repo).

Locked 8 Oct 2026. The same text lives on the Membrae track as the note “ChatGPT and Claude import spec.”

Web ChatGPT and web Claude can create records in Membrae on this Mac. They cannot read notes, tracks, or decisions that already exist. There is no Membrae account. Cursor’s local `membrae-mcp` is unchanged.

This is not Settings → ChatGPT. That page signs in so Membrae can talk with the user’s ChatGPT plan. This feature is the other direction: a browser chat writes into Membrae.

## 1. What the user is trying to do

They have been working in ChatGPT or Claude in a browser. They want that chat to file the work into an existing Membrae project: one new track, then notes and decisions from the conversation. They do not want the chat to see what is already in the project.

They create a key in Membrae, paste a URL and that key into ChatGPT or Claude as a custom MCP, and leave Membrae open. The chat lists project names, creates a track, and writes notes and decisions. Those records appear in the project the same way a local create does.

## 2. Placement in the app

New Settings section, under Account, after Cursor.

- Title: Import
- Symbol: `square.and.arrow.down`
- No brand mark (there is no Claude mark, and this page is not the ChatGPT account)

Settings → ChatGPT stays only “use my plan to talk inside Membrae.” Do not add import controls there.

There is no onboarding prompt, menu-bar extra, dock badge, or empty-state nudge elsewhere. The user who wants this opens Settings → Import.

## 3. Settings → Import

Use the existing Settings page: `SettingsPage`, one plate per `SettingsGroup`, `SettingsRow` + hairlines, system trailing controls. Copy is sentences, like the ChatGPT connect sheet. No slogans.

### 3.1 No key yet

**Group: Import**

Lead row, two lines:

- Title: Import from a browser
- Caption: ChatGPT and Claude can add a new track, notes, and decisions to a project. They cannot read what is already in Membrae. This Mac must stay open.

If the store has no projects, a second caption under that: Create a project in Membrae first. The chat can only add to a project that already exists.

Row: Lifetime. Trailing control is a menu: 1 day, 7 days, 30 days, 90 days, 180 days, Custom. Default is 7 days. Custom shows a days field, integer 1 through 180. Invalid values snap to the nearest bound when they create the key.

Row: primary action Create key. Creating the key does not need the relay to be reachable. If Keychain write fails, stay on this state and show the error under the button in 12pt red, same as connect sheets.

### 3.2 Key just created

Same page. Do not use a modal for the first create. The URL and the full key appear on this page immediately.

**Group: Import**

- Status row. See §5.
- Expires row. Absolute date and time, plus a relative clause when under 24 hours (“Expires in 6 hours”).
- URL row. Full URL, selectable, trailing Copy. After copy, the button reads Copied for 1.5 seconds. No toast.
- Key row. Full key, selectable, monospaced, trailing Copy (same Copied behavior). Caption under the key: Copy this now. Leaving this page hides it. If you lose it, create a new key.
- Last import row. Hidden until the first successful write. See §8.
- If there are no projects, keep the “Create a project first” caption.

**Group: Set up ChatGPT**

Numbered steps. Exact ChatGPT menu names change; keep these steps as copy on the page so they can be edited without a code change to the flow:

1. In ChatGPT, turn on Developer Mode (Settings → Apps, or the current equivalent).
2. Create a custom MCP app named Membrae.
3. Server URL: the URL shown above.
4. Authentication: Bearer token. Paste the key.
5. In a new chat, enable the Membrae connector.

Trailing button: Open ChatGPT. Opens `https://chatgpt.com`.

**Group: Set up Claude**

1. In Claude, open Settings → Connectors (or the current equivalent).
2. Add a custom connector named Membrae.
3. Server URL: the URL shown above.
4. Paste the key as the API key / bearer token.
5. In a new chat, enable the Membrae connector.

Trailing button: Open Claude. Opens `https://claude.ai/settings`.

**Group: Key**

- New key… — opens the replace modal (§3.4).
- Expire — immediate, same as Remove on the Cursor API key. Deletes the Keychain item, clears local metadata, disconnects the socket. The page returns to §3.1. ChatGPT and Claude start failing on the next call.

### 3.3 Key exists, user came back

Same as §3.2, except the Key row no longer shows the secret. It shows `Hidden · last four {xxxx}` and the caption: The key is not shown again. Create a new key if you did not copy it.

URL stays visible and copyable.

Leaving the page is what hides the key. There is no “I saved it” button.

### 3.4 Replace key modal

`AppModal` through `MembraeModal`, 440 wide, same chrome as other connect/edit modals.

- Title: Replace import key
- Body: ChatGPT and Claude will stop until you paste the new key into both.
- Lifetime control, same options as §3.1, default 7 days.
- Footer: Replace key (primary) / Cancel.

On Replace key: expire the old key, disconnect, create the new one, dismiss, return to §3.2 with the new key visible.

### 3.5 Expired key

The page looks like §3.1, plus one caption: The last key expired {date}. Create a key to continue.

The expired secret is already gone from Keychain. URL is not shown until they create a new key (the URL is stable, but there is nothing to connect until a key exists).

## 4. Key

Format: `slt_` plus 32 random bytes, hex-encoded (64 hex characters).

Store:

| Item | Where |
| --- | --- |
| Raw key | Keychain, new account `import-key` |
| Expiry, created at, last-four, ids of tracks created with this key, last import | Local metadata next to the app (not Keychain). Not secret. |

Rules:

- One live key on this Mac.
- Creating a key expires the previous key and drops the previous socket.
- Expiry and Expire are the same outcome: Keychain item gone, metadata cleared, socket down.
- The Cloudflare Worker stores only SHA-256 (hex) of the raw key, the expiry timestamp, and the live socket. It never stores the raw key.
- Restarting Membrae does not require a new key. On launch, if a key exists and is not expired, reconnect with that key.
- Changing lifetime requires a new key.
- After a new key, the user pastes it into ChatGPT and Claude again. There is no push to those products.

Two Macs: the Worker keeps one hash and one socket. The Mac that connected last receives the calls. Creating a key on a second Mac replaces the first. That is acceptable. Do not add accounts to fix it.

## 5. Connection status

The Status row is text, not color-only.

| State | Label | When |
| --- | --- | --- |
| No key | (row hidden) | §3.1 / §3.5 |
| Connecting | Connecting | Key exists, socket not up yet |
| Ready | Ready. Membrae must stay open. | Socket up, key not expired |
| Reconnecting | Reconnecting | Socket dropped; retrying |
| Relay unreachable | Can’t reach the import relay | TCP/TLS/HTTP to the Worker failed |
| Expired | Expired | `now ≥ expiresAt` |

Transitions:

- Create key → Connecting → Ready or Relay unreachable.
- Sleep, lid close, network drop → Reconnecting, then Ready or Relay unreachable.
- Quit Membrae → socket gone immediately. Next ChatGPT/Claude call fails with “Membrae is not open on the Mac.”
- Wake or relaunch with a live key → Connecting.
- Clock passes expiry (check on appear, when the status refreshes, and when a call arrives) → Expired, disconnect, delete Keychain item.
- Worker process restarts and forgets memory → Mac’s socket drops → Reconnecting. On success the Mac presents the key again and the Worker stores the hash again. No Worker database.

Backoff while Reconnecting: 1s, 2s, 5s, 10s, then 15s. No user-facing retry button required; the status line is enough. Opening the Import page can trigger an immediate retry.

In-flight tool call when the socket dies: the Worker returns “Membrae is not open on the Mac.” Nothing is queued.

## 6. Why a Cloudflare Worker exists

ChatGPT and Claude run on OpenAI’s and Anthropic’s servers. They cannot open `localhost`. A custom MCP connector needs a public HTTPS URL that speaks MCP Streamable HTTP. The path is `/mcp`.

That URL is one Cloudflare Worker deployed from this repo. It is not a Membrae backend. It does not store notes, tracks, decisions, or projects. It does not create user accounts. It does not keep a write to retry later.

The Mac app is compiled with the Worker URL. A `*.workers.dev` name is enough. No custom domain. No Cloudflare KV or Durable Object for v1: state lives in the Worker isolate. The Mac re-registers the hash every time it connects.

Until the Worker is deployed, Settings still lets the user create a key. Status stays “Can’t reach the import relay.”

Developer → Import relay URL: optional override, empty means the baked-in URL. For local testing only.

Do not use OpenAI’s Secure MCP Tunnel. It is ChatGPT-only.

Do not require ChatGPT Desktop or Claude Desktop.

## 7. How a call works

1. Membrae is open and a key is live. Membrae holds one WebSocket to the Worker and sends the raw key plus expiry. The Worker stores the hash, expiry, and that socket. A new socket with a different key replaces the previous hash, expiry, and socket.
2. ChatGPT or Claude `POST`s to `{relay}/mcp` with `Authorization: Bearer {key}` (also accept `x-api-key`). Streamable HTTP MCP.
3. The Worker hashes the presented key (SHA-256 hex). If it does not match, or expiry has passed, it returns the matching error in §10 and does not talk to the Mac.
4. If there is no socket, it returns “Membrae is not open on the Mac.” It does not answer `tools/list` in that state. A closed app must not look like a working connector.
5. If the socket is up, the Worker forwards the MCP JSON-RPC message to the Mac and returns the Mac’s result. The Mac is the MCP server. The Worker is transport. Session ids are bound to the current socket; a dropped socket ends the session.
6. The Mac runs the tool on the same SwiftData store the windows use, then posts `Store.changedNotification` so open windows refetch, same as `membrae-mcp`.

The Worker answers nothing from a local tool catalog. `initialize` and `tools/list` run on the Mac so the allowlist cannot drift.

Parallel tool calls are serialized on the Mac (SwiftData / main actor). Do not fail the second call; wait and run it.

If the Mac does not answer in 30 seconds, the Worker returns “The import relay could not reach Membrae in time.”

Payloads over 200 KB are rejected.

Rate limit: 60 tool calls per minute per live key. Over: “Too many import calls. Try again in a minute.”

Do not log the raw key on the Mac or the Worker.

## 8. What appears in Membrae after a write

The record is a normal track, note, or decision. No new type. No import badge on the row. No toast (the user is in the browser; Save-from-chat toasts stay for in-app chat only).

If they are looking at that project, the new row appears after the store notification. If they are elsewhere, they find it in the project.

Settings → Import shows Last import after the first success: `{kind} “{title}” in {project} · {time}`. Kind is Track, Note, or Decision. This is how they confirm it worked without a log. Only the latest write. Cleared when the key is expired or replaced.

Note.`source` is set by Membrae, not by the model. If the Worker can tell the caller is ChatGPT or Claude (User-Agent or a client header), use `ChatGPT` or `Claude`. Otherwise `Imported`. Ignore a `source` argument from the model.

Tracks and decisions have no source field. They are ordinary records.

## 9. Remote tools

Only these four. Do not expose the rest of `membrae-mcp`.

`list_projects` descriptions must tell the model: pick a project by name, then create a new track for this import, then add notes and decisions. Do not invent a project id.

### 9.1 `list_projects`

No arguments. Read-only.

Each item:

```json
{ "id": "<uuid>", "name": "<name>", "summary": "<summary>", "status": "active|paused|done" }
```

Include every project, including paused and done. Status is allowed so the model can prefer an active project with the same name. Do not return `current_direction`, counts, next task, notes, tracks, decisions, symbols, or pin state.

Writes to paused or done projects are allowed.

### 9.2 `create_thread`

Allowed arguments: `project_id`, `title` (required), `kind`, `status`, `summary`, `body`, `parent_id`.

Defaults match local create: kind `topic`, status `exploring`.

Returns the same thread shape as local `create_thread` (including `id`) so a later call can nest.

`parent_id` is accepted only if it is in the allowlist for the current key: thread ids created through this import path while this key has been live. Persist that list with the key metadata so a Membrae relaunch in the middle of a chat still allows a subtrack. Replacing or expiring the key clears the list.

Any other `parent_id` — including a real track the model guessed — fails with the existing-track error in §10.

### 9.3 `create_note`

Allowed arguments: `project_id`, `title`, `content` (required), `thread_id`.

`source` from the model is ignored. Membrae sets it (§8).

`thread_id` omitted: project-level note. `thread_id` set: must be on the allowlist. Same error as a bad `parent_id` otherwise.

Returns the local `create_note` shape.

### 9.4 `create_decision`

Allowed arguments: `project_id`, `title` (required), `decision` (required), `rationale`, `thread_id`.

`supersedes_id` is rejected. The chat cannot see existing decisions, so it cannot replace one.

`thread_id` follows the same allowlist as notes.

Returns the local `create_decision` shape.

### 9.5 Filing

Every create requires a `project_id` that exists. There is no default project in Settings. Do not create a project because the model guessed a name.

Typical sequence: `list_projects` → `create_thread` → `create_note` / `create_decision` with that `thread_id`.

A second import of the same conversation creates another track. No dedup.

The chat cannot update or delete. A bad import is edited or marked for deletion in Membrae, by the user or by a local agent.

## 10. Errors the chat sees

Plain sentences. Do not leak Keychain, hashes, or internal paths.

| Situation | Message |
| --- | --- |
| No socket / Membrae quit / asleep and not yet reconnected | Membrae is not open on the Mac. |
| Key unknown | This import key is not valid. |
| Key past expiry | This import key is expired. |
| Unknown tool | This tool is not available. |
| Unknown `project_id` | That project does not exist. |
| `parent_id` / `thread_id` not on the allowlist | Create a new track in this import, then file under it. Existing tracks are not available. |
| `supersedes_id` sent | Import cannot replace an existing decision. Create a new one. |
| Timeout | The import relay could not reach Membrae in time. |
| Payload too large | That import is too large. |
| Rate limit | Too many import calls. Try again in a minute. |
| Relay down (ChatGPT cannot reach the Worker) | whatever the platform shows; Membrae is not in that path |

Local validation errors (empty title, invalid kind) can use the same wording as `membrae-mcp`.

## 11. Lifecycle walkthrough

**First time.** Settings → Import → leave lifetime at 7 days → Create key. Copy URL and key. Follow Set up ChatGPT (or Claude). Leave Membrae open. In the browser chat, enable Membrae, ask it to file the work in the named project. `list_projects` returns names. `create_thread` adds a track. Notes and decisions land under it. Opening that project shows them. Import page shows Last import.

**Come back tomorrow, same key.** Membrae was quit overnight. Launch Membrae. Status goes Connecting → Ready. ChatGPT still has the old key. Imports work. The key row is Hidden.

**Lost the key.** New key… → confirm → copy the new one → paste into ChatGPT and Claude. The old connector fails until they do.

**Expired.** At expiry the page says the last key expired. ChatGPT gets “This import key is expired.” Create key.

**Quit mid-write.** The call fails. Reopen Membrae, retry in the chat. Nothing is waiting in the cloud.

**No projects.** Create key still works so they can finish ChatGPT setup. Creates fail until they add a project.

**Worker redeploy.** Brief Reconnecting. Mac presents the key again. No user action if Membrae is open.

**Two machines.** The second Mac’s key or socket wins. The first Mac’s Status may still say Ready until its socket is dropped; then Reconnecting or Ready on the loser fails tool calls. Document in the Import caption if we need a second sentence: Imports go to the Mac that created the current key and is open.

## 12. Out of scope

- Membrae accounts, a hosted database of user data, or a product API
- Two live keys on this Mac
- Queued writes while Membrae is closed
- Reading existing tracks, notes, or decisions from the remote chat
- `get_project`, updates, deletes, tasks, `create_project`
- Replacing Cursor’s local MCP
- Requiring desktop ChatGPT or Claude
- OpenAI’s tunnel
- OAuth for the connector (Bearer only, until a platform requires otherwise)
- Toasts, badges, or an import history beyond Last import
- Confirming each remote write
- A Claude brand mark

## 13. Build list

1. Cloudflare Worker in this repo: WebSocket from the Mac, `POST /mcp`, hash + expiry in memory, forward JSON-RPC, errors in §10, 30s timeout, 200 KB cap, 60 calls/min.
2. Mac: Keychain account, metadata, lifetime, create / replace / expire, hide key after leaving the page.
3. Mac: one socket while a key is live; reconnect on launch, wake, and drop.
4. Mac: import tool host with the four tools and the allowlist.
5. Settings section and page as specified. Developer relay URL override.
6. Deploy the Worker; bake the URL into the app.

UI copy for the ChatGPT and Claude steps is part of the page, not a one-off alert.
