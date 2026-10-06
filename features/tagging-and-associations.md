# Tags and associations

Plan from 30 Sep 2026. First cut is in. Decisions below are locked.

Two systems. Do not merge them.

- **Tags** are labels you invent in Settings. Any tagged object can have many. They do not own anything and they do not imply a project.
- **Associations** are links between objects. They are how a reminder, event, or task sits on a track, a note, or a project.

Projects do not get tags. A project is a container. You find work in a project by looking at what is in it, or by tags on those objects.

App tasks are the same Slate object as a reminder, stored on `AgendaItem` instead of EventKit. Do not hang tags off EventKit identifiers.

## What already exists

Associations do not replace this ownership.

| Object | Belongs to | Optional extra |
| --- | --- | --- |
| Track | one Project | parent track |
| Note | one Project | one Track |
| Decision | one Project | one Track |
| Conversation | one Project (nullable in code) | one Track |
| Chat message | one Conversation | — |
| Reminder | EventKit list | scratch text |
| Task | Slate | scratch text |
| Event | EventKit calendar | scratch text |

A note or track always has a project. That is why linking one to a reminder can fill in the project.

An EventKit list is not a Slate project. A calendar is not a Slate project. Those stay independent.

Scratch text on a reminder or event is not a Slate Note. Both can exist on the same item.

## Who gets what

| Object | Tags | Project | Tracks | Slate Notes | Decisions |
| --- | --- | --- | --- | --- | --- |
| Project | no | — | owns them | owns them | owns them |
| Track | yes | already has one | — | already has notes | already has decisions |
| Note | yes | already has one | already optional | — | no |
| Decision | yes | already has one | already optional | no | — |
| Conversation | yes | already has one | already optional | no | no |
| Chat message | no | via conversation | via conversation | no | no |
| Reminder / Task | yes | at most one | many, same project | many, same project | no |
| Event | yes | at most one | many, same project | many, same project | no |

Reminders and events do not link to decisions. A decision can sit on a project with or without a track. Work that implements it hangs on the track if it has one, or on the project.

A reminder or event has one project. Cross-project meaning uses tags.

One Slate Note can sit on many reminders, events, or tasks.

## Tags

Created and managed in Settings. Global, not per project. Same tag on a note in Project A and a track in Project B is the same tag.

A tag is: name, optional color or symbol, stable id. Names are unique, case-insensitive.

- Many tags per object.
- Tags do not inherit down a track tree. Tagging a parent does not tag its children.
- Tags do not assign a project.
- Deleting a tag removes it from every object.
- Rename keeps the id. Merge is a later Settings action if two names collide.
- Create-on-tag is allowed. Creating a tag from an object adds it to the same Settings vocabulary.

Taggable: tracks, notes, decisions, conversations, reminders, events, tasks.

Not taggable: projects, chat messages.

Recurring events: tags and associations belong to the **series**, not one occurrence.

First tag or first association on an EventKit reminder or event creates the Slate record. Items you never touch have no Slate row.

Slate tags and links still work when the EventKit item is read-only. EventKit write is only for title, due, list/calendar, and scratch text.

Surfaces that show tags: the object itself, and Home / Tasks / Calendar rows. A unified “everything with this tag” index is its own later project. The data model does not wait on it.

## Associations

On a reminder, event, or task:

1. **Tags** — any number.
2. **Project** — at most one. User-set or inherited.
3. **Tracks** — any number, all in that project. Each link is user-set or inherited.
4. **Slate Notes** — any number, all in that project.
5. **Scratch text** — the EventKit notes string. Shown under the item’s name. Not an object.

**Inherit** is the UI word. Never say derived.

If a property is inherited, put the link symbol (`link`) in the app accent next to it. Accessibility label / help: “Inherited”. If the user set it, no icon.

The link is bidirectional. A reminder on a track appears on the track. Same for a note and a project.

A project page shows every reminder and event whose project is that project, including ones with no track.

A track page shows items linked to that track **and** its children, with the child named.

Completed reminders keep tags and links. Filter them off the track’s current list.

Save-from-chat and later MCP take the open project and track as the first association.

### Notes on a reminder or task

Three things, all allowed:

| Thing | What it is | How it looks |
| --- | --- | --- |
| Scratch text | EventKit notes string | Line under the item’s name |
| Linked Slate Note | existing document | An object on the item |
| New Slate Note from the item | create a note, then link it | Same as a linked object |

Creating a **reminder or task from a Slate Note**: the item’s title is the note’s name at that moment. That title is a snapshot. Renaming the note later does not rename the item. The note is linked as an object. Fill-in then runs: project from the note, and the note’s track if it has one (inherited).

Creating a **note from a reminder**: the note belongs to the reminder’s project (pick one first if empty), then the reminder links to it. Fill-in runs as usual.

### Project fill-in

Project is one field. It is **user-set** or **inherited**. Never switch it silently.

1. User picks a project. Mark it user-set. Later links do not change it unless the user confirms a switch.
2. User links a track or a Slate Note, and project is empty. Set project to that object’s project. Mark it inherited.
3. Linking a Slate Note also links that note’s track when the note has one. Mark that track link **inherited**, unless the track is already on the item as user-set. Then the same-project rule runs.
4. Another track or note from the **same** project: keep the project.
5. A track or note from a **different** project: ask. Do not switch on their behalf.
   - Keep the current project and refuse the link, or
   - Switch project and drop links that do not belong to the new one.
6. User unlinks the last track/note that justified an inherited project. Clear the project. If the project was user-set, leave it.

A project-only item is valid. An item with no project is valid.

### Track fill-in (note → track)

Same inherited vs user-set idea, on the track link.

- Attaching a note attaches that note’s track as **inherited**, if the note has a track and the item does not already have that track as user-set.
- Unlinking the note: drop every track link that was inherited from that note and is not still justified by another linked note. User-set tracks stay.
- Unlinking a track never unlinks the note.
- User attaches a track themselves: mark it user-set. Unlinking notes will not remove it.

### Moving a note or track

Allowed. Confirm or cancel. Nothing is deleted. Links stay.

The dialog lists everything that will change project if they confirm: the object they are moving, plus linked reminders / events / tasks. Moving a track also lists its notes, decisions, and child tracks.

On confirm, all of that moves to the new project. Same-project still has to hold, so if a linked reminder also has another note or track in the old project, those are in the list and they move too.

On cancel, nothing moves.

Do not send anything to Deleted for a move. Do not drop links.

### What does not auto-happen

- Tagging never assigns a project.
- Tagging a track never copies that tag onto items linked to it.
- Completing a reminder does not change its track or note.
- No silent project switch. No silent move.

## Deleted

Broken links do not auto-drop and do not vanish. They go to a **Deleted** section. The user decides per item.

What lands there:

- A linked note or track was deleted.
- The EventKit reminder or event was deleted outside Slate, so the Slate record has tags and links but no live calendar/reminder item.

What the user can do there: drop the link, pick a replacement, delete the Slate record, or ignore it until later.

While a broken link is still in Deleted, do **not** clear an inherited project. The item stays where it was until the user resolves that row. When they drop the last link that justified the inherited project, then clear it. When they pick a replacement, fill-in runs again.

Archived tracks are not deleted. Keep the link. Hide those items on views that already hide archived work.

## Slate record

Tags are their own SwiftData model.

Reminders, events, and tasks share one Slate-side record (`AgendaItem`):

- `kind`: reminder | event | task
- EventKit identifier, nullable
- tags
- project, plus user-set vs inherited
- tracks, each user-set vs inherited
- notes

EventKit mirrors title, due, list/calendar, and scratch text. It is not the source of truth for tags or links.

Tasks persist the body (title, due, complete, scratch, repeat) on this record. Reminders and events still mirror title, due, list/calendar, and scratch from EventKit.

Recurring events store tags and associations on the series.

## Later, not this model

A single Home list of every object with a given tag. Own project. Do not block the model on it.
