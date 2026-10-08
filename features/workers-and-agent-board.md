# Workers and the agent board

Plan from 5 Oct 2026. Direction is locked. UI is not.

Slate is the project. Coding agents are workers. A pull request is the receipt.

A project is goals, direction, decisions, tracks, and what’s next. Repos are where work lands so the project can run. Issues are the tickets in someone else’s tracker. Tasks are what you made yourself responsible for. Most projects have more than one moving part. They are never just a git repo.

A PR documents what changed, on which component. It does not own the reason the work existed. An issue is also not that reason — the track is.

## Two paths

Every worker is one of these. The board is the same.

| Path | Where it runs | Slate closed / lid down | Several at once |
| --- | --- | --- | --- |
| **Local** | This Mac, one folder (`cwd`) | Stops (unless detached; then the board goes dark) | Yes. One process per job. Same checkout will collide; different repos or worktrees will not. |
| **Cloud** | Their VM | Keeps going | Yes, subject to that vendor’s caps |

Cursor does both. Local is what Slate chat already is (`@cursor/sdk` + `local.cwd`). Cloud is `POST /v1/agents` (or SDK `cloud.repos`). A public Slate offers both: local for “I’m here, work in this checkout,” cloud for “go do it, I’m leaving.”

## The join

Handoff out: brief + decisions + which repos + who should run it.

Handoff back: queued / running / waiting / done / blocked, plus a summary, a branch, and a PR link when there is one. That write-back is the documentation.

You open the vendor UI for the transcript or the diff. Slate does not rebuild their agent view.

## Three kinds of work

We do not have issues yet. Slate Tasks are personal. They are not Linear issues and they are not GitHub issues. Do not merge these.

| Object | Question | Source of truth | Lives in Slate as |
| --- | --- | --- | --- |
| **Task** | What did I make myself responsible for? | Slate (`AgendaItem`). Reminders still mirror EventKit. | The object itself |
| **Issue** | What’s on the product / team board? | Linear, GitHub Issues, or GitLab Issues | A cached **ref**. We do not own the ticket. |
| **Run** | Who is executing, right now? | Slate, plus the worker’s id | The object itself |

A project overview needs all three, linked, not flattened into one list.

```
Track (why this exists)
  ├── Issue ref   HAR-184     "what's on the board"
  ├── Task        Review copy "what I owe"
  └── Run         Cursor      "what's executing"
        └── PR    #41         receipt
```

A task can sit on an issue (“remind me to review HAR-184”) without becoming HAR-184. A run can implement an issue. Completing a run does not complete a task or close an issue unless the user (or that tracker) says so.

Linear, GitHub, and GitLab are where tickets can come from. The board is ours, shaped like Linear.

### Issue

One object. It sits on a board. You drag it.

The board is Linear’s: Backlog, Todo, In Progress, Done, Canceled. You can add columns the way Linear does (In Review under In Progress). If the project is connected to a Linear team, those *are* the columns.

GitHub and GitLab issues land on that same board. They also have open/closed over there — that’s just whether they closed the ticket. Close it on GitHub, it goes to Done here. We do not write the board back to GitHub.

A PR is not an issue.

Two sides. What Linear understands can go to Linear. Notes and tracks stay here.

**Goes to Linear** (same fields as `IssueCreateInput`): title, body, column → `stateId`, priority `0–4` (none / urgent / high / normal / low), estimate, parent, due date, assignee. If there is no Linear team yet, we still store them.

**Stays in Slate:** project, tracks, notes. Same association rules as a task: many tracks, many notes, same project. A linked note is not the issue body. Tags later, same as a task.

The pane is an overview. You can move the column, set priority, due, assignee, attach notes and tracks. Comments and the rest stay in Linear. A button opens the issue in Linear’s app if it’s installed, otherwise the browser. Same pattern for GitHub and GitLab. A PR is still a receipt, not an issue field.

| Field | Ours or theirs | Notes |
| --- | --- | --- |
| Source / their id / identifier / URL | cache | Poll and open |
| Title / body | both | Body ≠ a linked Note |
| Column | both | → Linear `stateId` when connected |
| Priority | both | Linear’s 0–4 |
| Estimate / parent / due / assignee | both | |
| Project | Slate | Required |
| Tracks | Slate | Many, same project |
| Notes | Slate | Many, same project |
| Extra | cache | Cycle, milestone, labels |

### What the project overview is answering

- **Mine** — Slate tasks due, plus issue refs where assignee is me.
- **On the board** — issue refs on this project, any assignee.
- **Executing** — runs.

Do not show those as one row type. The Work page is runs. Tasks stay Tasks. Issues are a third list (or a section on the project), once we have a provider.

## Durable object

A **run** hangs off a track (or a task on a track). Not off the project as `cursorAgentId`.

| Field | Notes |
| --- | --- |
| Provider | `cursor`, `copilot`, `jules`, `devin`, `claude-cli`, … |
| Model | The model on the run. Shown as a mark, not a sentence. |
| Path | local or cloud |
| Their id | Adapter-private |
| Repos | Which execution surfaces this job uses |
| Branch | The branch it is on, once Cursor (or anyone) has one. Omit the field until it exists. |
| Status | queued, running, waiting, done, failed, cancelled |
| Receipt | summary, branch, PR URL |

### List row

Same row on the Work page and anywhere a run appears in a list.

| Lane | Width | What |
| --- | --- | --- |
| Status | 22 | Dot. Accent if running, tertiary if done / waiting. |
| Model | 22 | Provider mark. Always present. This is how you see who is working. |
| Title | flex | The run name (usually the track). 13 medium. |
| Subtitle | flex | Project · track. 12 secondary. Drop the project when you are already in that project. |
| Meta | flex | repo · branch (if any) · Cloud/Local. 11 tertiary. Done rows swap branch for the PR when there is one. |

No trailing “Cursor · Cloud” text. The mark plus the last meta word do that.

### Run document

Opening a row. Not a transcript.

1. **Status card** — running / waiting / done, how long, model mark, path.
2. **Brief** — the track text that was sent.
3. **Working on** — each repo, and the branch when it exists. “No branch yet” if it has not pushed.
4. **Receipt** — PR link, or “No pull request yet.”
5. **Follow-up** — the composer. Open in Cursor (or the vendor) is the page action.

Chat in Slate can stay Cursor-first for a while. The execution board is multi-worker from day one.

## Who can close the loop

First-class adapters (dispatch + status + PR from an API):

- **Cursor cloud** — best first. Paid plans include the VM (Pro and up; Hobby does not). Usage is model tokens, not a VM fee. Several repos possible with the right environment. `GET /v1/repositories` lists Cursor’s GitHub App repos (GitHub only, rate-limited).
- **Copilot cloud agent** — Business/Enterprise. One repo per task. User PAT. Preview API.
- **Jules** — alpha API. One repo per session. Jules GitHub App first. Plan caps on daily/concurrent tasks.
- **Devin** — org API, paid. Status and PR URL. “Waiting on you” is first-class.

Local CLIs (Cursor SDK, Claude Code, Codex, …) are workers too. Several processes on this Mac. Slate starts them; quit Slate and they die. Receipt is DIY unless they print a PR.

Do not pretend to drive **Claude Code cloud** or **Codex Cloud** from Slate. Those UIs exist. They have no supported coordinator API.

GitHub is never automatic. Someone’s App or a token you collected. A GitHub login can list issues and PRs. It still does not make an issue a Slate task, and it does not make a PR an issue.

## Repos on a project

Attach many. They are components, not the project. Connecting a repo requires a Slate project (pick one or make one). That is how issues and PRs find Harbor. Do not also create a GitHub/GitLab Project, and do not write a default status onto their issues. Open stays open.

A run picks which ones it needs. Most jobs hit one. A few hit two. Default Cursor-hosted cloud is usually one repo; several in one run needs an any-repo pool or a named environment (max 20 on create). Copilot and Jules are one repo per job — N jobs for N repos.

Do not connect GitHub in Slate just to launch Cursor. Cursor’s (or Jules’s, or Devin’s) own GitHub connection is what clones and opens the PR. A Slate GitHub login is only for browsing, issue/PR links, or a local clone.

## Sidebar and project view

Open. Explore in Paper. Constraints from `DESIGN.md` still apply until we change them:

- Sidebar is locked: 232 wide, 28-tall rows, no badge except the Tasks due count. Chats is the workspace page for Slate conversations (running plus recent). It is not the Work page.
- One job per view. Rich, not busy.
- The same object is edited the same way everywhere.

What we need to see: what’s in flight across the app, and what’s in flight on this project.

Two Issues pages, same convention as Tasks vs a project:

- **Workspace Issues** — main sidebar, next to Tasks. Every issue. Row/card shows the project. No project column.
- **Project Issues** — Harbor (etc.) selected, Issues in the project column like Overview. Only that project’s issues. No project name on the card.

Both swap Board / List.

### Issue pane

One pane. Same fields, same actions, wherever you open it (workspace board, workspace list, project board, project list). Ask Slate–style, 360, trailing edge.

Overview first: identifier, title, body, column, priority, due, assignee. Then Slate links with `AssociationOpenRow` (Tracks, Linked notes). Then deploy.

**Workers connected**

- Worker (menu) and Repo (menu)
- **Deploy** — primary capsule. Starts a run on this issue.
- **Open in Linear** (or GitHub / GitLab) — source mark left, arrow out right

**No workers**

- One line, tertiary: “No workers connected.”
- **Add a worker** — primary capsule. Opens the Add Worker modal.
- Open in source, same as above

Do not invent a second pane. Do not hide deploy on the project page.

### Add Worker

Slate modal. Title “Add Worker”. Worker (menu: Cursor, Copilot, Jules, Devin, Claude CLI), Path (Local / Cloud, when that adapter has both), credential field. Add / Cancel.

Connect… on a Settings row opens this same modal.

### Settings

New sections in the settings column, under Account:

**Sources** — Linear, GitHub, GitLab. Connect… / team or account name + Remove. This is how issues get onto the board.

**Workers** — one row per adapter (Cursor · Cloud, Cursor · Local, Copilot, Jules, Devin, Claude CLI). Connected + Remove, or Connect…. Cursor · Local is this Mac; no key.

Cursor under Account stays the chat / API key. Cloud worker can use that same key.

### Empty

If no worker is connected: Work page is one tertiary line, “No workers connected.” Same sentence on the issue pane. No illustration.

## Do not

- Rebuild Cursor’s (or anyone’s) Agents view.
- Hang `cursorAgentId` on the project as the source of truth.
- Treat a repo as the project.
- Fake a live transcript for a cloud run.
- Wire ChatGPT → Cursor MCP. Different plan.
- Auto-run a worker consult before every project chat. The worker is a tool. See [`worker-as-tool.md`](worker-as-tool.md).
- Ship Claude Code cloud or Codex Cloud as adapters until they publish a list/status API.
