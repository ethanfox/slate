# Sync wire contract: what the Mac sends to Cloudflare and expects back

Written 15 Oct 2026 from `PersonalContext/Services/SyncCodec.swift` and `SyncController.swift`. The Mac half of the third stop of the track "Cloud sync, sign-in, and privacy" is built in PC-OS. This is the contract the Cloudflare half in slate-web has to answer. Until the second stop (passkey and device keys) exists, the Mac signs with its import key.

## Requests

Both carry `Authorization: Bearer <import key>`, `X-Membrae-Role: mac`, `X-Membrae-Device: <device id>`. The device id is a UUID the Mac makes once and keeps in preferences. The relay address is the import relay's (default `https://mcp.membrae.com`, overridable in Settings → Developer).

**POST /sync/push** body:

```json
{ "v": 1, "device": "<device id>", "changes": [ "<record>", "..." ] }
```

Reply: `{ "accepted": <n>, "cursor": <database sequence after these> }`. Batches are at most 200 records, oldest first. The same record may be pushed again after a failure; writes must be idempotent on `kind` + `id`.

**GET /sync/pull?since=<cursor>&device=<device id>**

Reply: `{ "changes": [ "<record>", "..." ], "cursor": <n> }`. Returns changes with a database sequence greater than `since`, oldest first, leaving out those pushed by this device. An empty `changes` with the same cursor ends the pull.

## A record

```json
{
  "kind": "note",
  "id": "<lowercase uuid>",
  "space_id": "<lowercase uuid or empty>",
  "deleted": false,
  "sequence": 42,
  "changed_at": "2026-10-15T15:07:16.575Z",
  "origin": "app",
  "fields": { "title": "…", "content": "…", "createdAt": "<iso date>", "isArchived": false, "fareDays": 0 },
  "links": { "project": "<uuid>", "thread": "<uuid>", "tags": ["<uuid>", "…"] }
}
```

- `kind` is a `ChangeKind` raw value: space, track, stop, theme, junction, requirement, note, decision, chat, message, task, task_track_link, task_note_link, completion, dependency, asset, asset_reference, tag, deletion_mark, code, run, type, record, event, fact, action, source, pin, widget, cleanup.
- `fields` holds every stored attribute by its Swift property name. Strings, numbers, and booleans as JSON; dates as ISO 8601 with milliseconds; ids as lowercase UUID strings; binary as base64; absent values as null.
- `links` holds relationships: a to-one as one id, a to-many as a list. The Mac applies to-one links on the way down; to-many links (tags, a source's Spaces) are carried but not yet applied.
- A deletion is `"deleted": true` with empty `fields` and `links`. It is a tombstone; keep it.
- `sequence` on the way up is the device's own counter; on the way down it is the database's. The database should keep one row per `kind` + `id` and give each write a rising sequence, the same shape as the Mac's `RecordChange`.

## The key

Until the second stop, the key is the import key. If it is missing or has expired when sync runs, the Mac makes a new one (180 days) rather than stop. The database in Cloudflare is named after the key, so a new key is a new, empty database: the Mac keeps a hash of the key its cursors belong to and, when it changes, pushes everything again from the start and pulls from the start.

## What goes up

Changes in Spaces whose `isSynced` is on, plus tags, sources, and facts (records outside any Space that belong to the user) once any Space is synced. Changes in local Spaces are passed over and the cursor still moves past them. Turning a Space on re-stamps every record in it so the first push sends all of it.

## Two edits to one record

The later `changed_at` wins. The Mac keeps its own unsent edit when it is later, and in either case writes the losing side to the action log so it shows in Lately. The database should do the same: accept a push only when its `changed_at` is later than the row it has, and otherwise answer the Mac's edit back in the next pull.

## Not in this half

- Files: `asset` rows travel as metadata only. The bytes need file storage under the user's id (R2) and a transfer step.
- Creation on the Mac of junctions, junction requirements, files, deletion marks, code attachments, agent actions, and cleanup plans from a pull; updates and deletions of them do apply.
- To-many link application on the Mac.
- The Cloudflare half itself: a Durable Object per user (keyed by the import key's owner until the passkey account exists) with one SQLite table of kind, id, space_id, deleted, sequence, changed_at, origin, fields JSON, links JSON, device; and an R2 bucket for files.
