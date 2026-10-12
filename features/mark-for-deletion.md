# Mark for deletion

Locked 7 Oct 2026. Changed 12 Oct 2026: agents can also delete outright.

An agent that is not sure something should go marks a note, track, decision, or chat. The user Keeps or Deletes. Delete means delete.

An agent that is sure deletes with `delete_record`, which also covers tasks. The delete is written to the action log, shows in Lately, and Take Back restores the record. A track with tracks under it is refused until those are moved or deleted. Runs cannot delete, and an agent cannot delete the chat it is in. Space records are not covered.

Archive stays chats-only. It is not a delete synonym. There is no auto-purge and no retention setting.

Decision supersede and track rejected/completed stay separate. Those are outcomes. This mark is a proposed removal.

## Mark

A `DeletionMark` hangs off the project.

- Required: reason
- Optional: one replacement in the same project (`kind` + `id`)
- Agent tool: `mark_for_deletion`. Calling again updates the reason and replacement.
- No unmark tool. Deleting outright is `delete_record`, a separate tool.

## Banner

Page chrome, same idea as the project chat title. Not the window toolbar. Not inside the document scroll.

Collapsed (default): red `xmark.octagon`, “Marked for deletion”, Keep, Delete, chevron. 52pt, 32 inset, canvas fill, hairline below.

Expanded: the reason, then the replacement as an object card if one was linked.

Keep clears the mark. Delete uses the existing confirmation and removes the record.

Ask Membrae (compact) does not get this banner.

## Project column

A marked row uses `xmark.octagon` in red in the icon slot. Title stays primary.

Context menu: Keep appears after the divider, before Delete, only while a mark exists.

## Confirm

Delete is a real delete. Child tracks go with a track. Notes and decisions stay in the project. Broken associations land in Settings → Tags → Deleted, as they do today.
