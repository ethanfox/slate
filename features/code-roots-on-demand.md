# Code roots on demand

Problem from 8 Oct 2026. Direction is locked.

Do not download, unpack, or refresh attached GitHub / GitLab code on every chat send. The model does not need a checkout to answer about a decision, a track, or what’s next.

## What’s wrong

`prepareCodeRoots()` runs at the start of every Cursor and ChatGPT turn. Local folders return a path. Remote attachments hit `ManagedCloneService`: if the snapshot is older than **60 seconds**, Membrae downloads the full ZIP, fetches 20 commits, unpacks, deletes the old snapshot, and moves the new files in. Only then does the request leave the Mac.

That burns time and tokens on messages that never look at code.

## What to do

- **Always cheap.** Prompt may say the project has attached code (`owner/repo`, branch). No ZIP.
- **Materialize on tool call.** `project_list_files`, `project_search_code`, `project_read_file`, `project_git_log`, and a worker consult call `prepareCodeRoots()`. Nothing else does.
- **Refresh by SHA, not by clock.** Ask the commits endpoint first. If the tip matches `.membrae-commits.json`, skip the archive. Drop the 60-second full-ZIP refresh.

Advertise the tools. Do not clone because the tools exist.

## Do not

- Call `prepareCodeRoots()` from `CursorChatProvider.stream` or `ChatGPTProvider.stream` before the model request.
- Treat “code is attached” in the prompt as a reason to download.
- Re-download the whole repo on a timer.

## Where it lives

`ProjectCodeWorkspace.prepare`, `ManagedCloneService.prepare`, `CursorConversationBridge.prepareCodeRoots`. ChatGPT executes project tools through `MembraeToolGateway`; Cursor through `PersonalContextRunner`.

See also: [`chatgpt-lazy-prep.md`](chatgpt-lazy-prep.md), [`worker-as-tool.md`](worker-as-tool.md).
