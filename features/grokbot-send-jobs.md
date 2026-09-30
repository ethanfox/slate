# Send jobs to Grok Bot

Plan from 30 Sep 2026. Not implemented.

Slate starts work. Grok Bot does it on its cloud computer. The user opens the Grok Bot Mac app to watch the run, approve sends, and read history.

This is the reverse of ChatGPT/Cursor-as-a-source. Those pull a model into Slate. This pushes a job out.

## Goals

- Send a named job from Slate to a Grok Bot routine.
- Each project can have its own Bot / webhook. A default account webhook is optional.
- Slate generates the setup instructions. The user creates the Bot and routine. Slate verifies the hook works.
- Do that from chat (MCP tool) and from a track.
- A track already has the brief (title, summary, body, linked decisions/notes). Sending it should attach that snapshot.
- After send, show “started” and a way to open the Grok Bot app. Do not pretend we have a webpage or a live transcript in Slate.
- Sensitive work (send email, publish) still stops for the user in Grok Bot. That is expected.

## What Grok Bot actually is

Same product in Cursor and in the Mac app. Same account, same Bots, same cloud computer. The Mac app (and iPhone) are the clients. Work runs in the cloud. Closing Slate or the Grok Bot app does not stop a run.

Cursor’s public API/SDK does **not** expose Grok Bot. `@cursor/sdk` and `POST /v1/agents` are coding agents. Do not use those to talk to a Bot. Do not use the undocumented port-1340 gateway.

The official way in: a **webhook routine** on a Bot. Many Bots, many routines. Typically one Bot (and one webhook) per Slate project.

## Auth / setup

No “Sign in with Grok Bot” API. No Cursor API key for this. Slate cannot create the Bot or the routine. The user does that. We write the prompt, they paste it, they paste the URL and key back, we ping the hook to prove it.

Account-wide, once:

1. Paid Cursor plan (or linked SuperGrok). Grok Bot is included.
2. Install the Grok Bot Mac app and sign in with the same Cursor account.

Per project (or a default in Settings):

1. Slate shows **Connect Grok Bot** and a generated prompt. Copy. Open Grok Bot. Paste.
2. The prompt tells the user to create a Bot named after the project and a webhook routine named “Slate jobs” with the instruction we wrote.
3. User copies **POST URL** and **bearer key** from the routine panel into that project in Slate.
4. Slate stores the key in the keychain, scoped to the project. URL lives with the project.
5. **Verify** in Slate: POST a harmless test payload (`{"name":"Slate verify","instruction":"Reply that the Slate webhook works. Do nothing else."}`). `200` + `runUuid` → Connected. Anything else → failed, keep the fields, show the error.
6. Verify is not a real job. It does not write an outbox row the user cares about. The user can open that Bot and see the test run if they want.

Slate then makes an **outbound** HTTPS POST to **that project’s** hook. Cursor does not need to reach this Mac. No open port. No Slack or Linear required.

A project with no hook cannot send. Chat/MCP uses the open project’s hook. Settings can hold a default hook for projects that have not set their own.

```http
POST <routine webhook URL>
Authorization: Bearer <key>
Content-Type: application/json
```

`200` + `{"success":true,"runUuid":"..."}` means the run started. It is not the result.

If the routine panel hides URL/key (server-stored routines bug), webhook setup is blocked until Cursor shows those fields. Slack/schedule are fallbacks, not the product.

## Shape

```
Slate project
  ├─ Generated setup prompt → user pastes into Grok Bot
  ├─ URL + key → Verify POST → Connected
  ├─ Track page  → “Send to Grok Bot”
  ├─ Chat / MCP  → send_to_grokbot
  └─ Outbox      → named job + runUuid
         │
         ▼
  that project’s webhook
         │
         ▼
  that project’s Bot / routine
         │
         ▼
  Cloud computer → user opens that Bot’s chat
```

One routine per project handles many named jobs. Different projects do not share a Bot unless the user pastes the same URL into both.

## Naming jobs

Yes. Every send has a name we pick.

- Job name: short, user-visible. “Draft launch emails”, “File the Linear tickets”.
- Optional instruction: what to do with the track if it isn’t obvious from the body.
- Routine name in Grok Bot stays generic, e.g. “Slate jobs”. The **Bot** is named after the project.
- Put `name` in the JSON so the Bot can title the run in chat. Grok Bot has no official “job title” field. The name we send *is* the name.
- Slate’s outbox is keyed by that name + time + `runUuid`.

Suggested body:

```json
{
  "name": "Draft launch emails",
  "instruction": "Write the three outreach mails. Do not send.",
  "source": "slate",
  "project_id": "…",
  "project_name": "…",
  "thread_id": "…",
  "track": {
    "title": "…",
    "kind": "feature",
    "status": "active",
    "summary": "…",
    "body": "…",
    "decisions": [],
    "notes": []
  }
}
```

Include the track snapshot in the POST. Grok Bot cannot read Slate’s local store. A later HTTP MCP can let it pull live data; v1 should not depend on that.

## MCP tool

`send_to_grokbot`

- `name` (required)
- `instruction` (optional)
- `thread_id` (optional; if set, attach that track’s snapshot)
- `project_id` (optional; if no thread, attach project context)

Used by the Slate chat agent so it can hand work off without the user leaving chat. Same POST as the track button. Same outbox row.

The open project must have a verified hook, or a default hook. Otherwise the tool fails with “Connect Grok Bot on this project.”

## Generated instructions

Slate writes the paste for the user. They do not invent the routine.

Include:

- Create a Bot named `{project name}`.
- Add a webhook routine named `Slate jobs`.
- Instruction we control: do the named job in the JSON; use `track` / project fields; draft first; do not send, publish, pay, or delete without approval; if `name` is `Slate verify`, reply that the hook works and stop.
- Then: copy POST URL and key back into Slate.

Show this on the project (and a shorter version in Settings for the default hook). Copy button. After they paste URL + key, Verify is the next control, not Send.

## Tracks

A track (`ProjectThread`) already is the brief: title, kind, status, summary, body, nested tracks, linked decisions and notes.

On a track: **Send to Grok Bot**. Fields: job name (default to the track title), optional extra instruction. Confirm. POST. Show started + Open Grok Bot.

Do not send the live SwiftData file. Send a snapshot. If the track changes after send, that is a new job.

Side-chat on a track can call the same MCP tool with that `thread_id`.

## What the user sees after send

- In Slate: outbox row — name, time, `runUuid`, started. Button that opens the Grok Bot app (deep link if we find a stable one; otherwise tell them to open that Bot).
- In Grok Bot: that Bot’s chat. The run is live. Tools, computer, questions, approve-to-send.

We cannot:

- Read official run history from Slate
- Link a public webpage of the transcript
- Approve email/send from Slate
- Get the finished artifact back unless the Bot writes it (MCP later, or we give it a callback URL)

History lives in the Grok Bot app: conversation + last 20 routine runs.

## Approvals

Grok Bot will ask. Sending email, publishing, paying, deleting — Auto Review stops for the user in the Grok Bot app. Feedback prompts too. Slate cannot click those.

Job copy should say “draft, don’t send” unless the user wants the Bot to wait on them.

## Out of scope / do not do

- Treat Grok Bot as a chat provider in the model picker.
- Call Grok Bot through `@cursor/sdk` or Cloud Agents.
- Watch a local folder or the SwiftData store.
- Build on the internal `:1340` gateway.
- Expect the webhook to return the finished work.
- Expect ChatGPT-style subscription login.

## Likely build order

1. Per-project hook: URL + key (keychain), optional Settings default.
2. Generated setup prompt + copy.
3. Verify POST in the app. Show Connected / failed.
4. Outbox model: name, project, payload, `runUuid`, startedAt.
5. Track button: name the job, send snapshot to **this** project’s hook.
6. MCP `send_to_grokbot` (same path, same project).
7. Open Grok Bot after send.
8. Later: reachable Slate MCP so the Bot can write results back.
