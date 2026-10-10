# Overview widgets

Plan from 1 Oct 2026. Decisions below are locked.

The overview is a project canvas of first-party widgets. Each plate is one widget instance. Settings live on that instance, never on the type.

Out: Status widget. Counts widget. Open Decisions.

## Catalog

| Kind | Job | First settings |
| --- | --- | --- |
| **Focus** | Show this project's tracks | Which track statuses appear |
| **Recent notes** | Notes in a window of time | Date range. Default last 14 days |
| **Countdown** | Time to a date | The date, plus a style |
| **Pinned text** | A short locked line | The text, plus formatting |
| **Image** | One picture as a face | Shape, fill, padding |
| **Downloads** | Files you can take | One or many, by plate size |

Connection widgets and AI layouts come after this catalog. AI emits catalog JSON, not freeform UI.

Sizes stay `1×1` / `2×1` / `2×2`. Same plate, different face.

## Editor

Every widget opens the same modal. Same presenter, scrim, glass, motion, and draft-until-save as other Membrae modals. Changing an input updates the preview immediately. Save writes the draft to that plate. Cancel discards.

- Title: `Edit` plus the kind name.
- Preview is the real face at the same cell size as the plate on the page. If the modal cannot fit that, the whole preview scales. It does not reflow. It does not navigate.
- Wide: preview leading, inputs trailing. Narrow: preview above, inputs below.
- Inputs use the existing modal field and control-row treatments. Toggles sit on the trailing edge.
- Size is an input in this modal so the preview can change.
- Esc cancels. Return saves.

`⋯` on a plate in edit mode opens this modal. That is the edit affordance.

## Settings storage

Each plate stores `kind` plus a JSON blob of its own settings. Two Focus plates on the same project can show different statuses. Missing `kind` on old layouts reads as Focus with default settings.

## Focus

Source: every track on the project, including children.

Filter: the statuses checked on that plate. Default: Exploring and Active. Empty means the plate is empty.

Sort: most recently updated first.

Face: a list. Kind symbol, title, status. Cap the list by size (`1×1` two, `2×1` four, `2×2` eight). No tracks: “No tracks”.

Clicking a row opens that track. Not while the inspector is open.

## Recent notes

Source: notes on the project whose `updatedAt` falls in the plate's range.

Range: start and end dates. Default start is 14 days ago, end is now.

Sort: newest first. Click opens the note.

## Countdown

One date on the plate. The face is the style the user picked. Styles:

- **Days** — remaining days as the number, “days left” as the caption
- **Date** — the target date as the number, remaining days as the caption
- **Split** — days and hours stacked

Past the date: “0 days” / “today”, not a negative.

## Pinned text

One string. Formatting on that plate: alignment (leading or center) and size (body, title, display). No markdown in the first cut.

## Image

One image. It can fill the plate, sit in a rounded square, or sit in a circle. Padding is none, 8, or 16.

## Downloads

Preview of files. Click a button to download.

- `1×1` — one file
- `2×1` — up to two
- `2×2` — up to four

## Insert

Insert will be by kind, with a default size. Size can change in the editor. Until that catalog is wired, new plates are Focus.

## Build order

1. Focus, plus the shared editor shell
2. Recent notes
3. Countdown
4. Pinned text
5. Image
6. Downloads
7. Insert by kind
