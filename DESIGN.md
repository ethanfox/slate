# Design (v2)

The window is glass. The page is solid. The app is native, a little more sophisticated.

Craft is the layout reference: one sidebar, a quiet toolbar, grouped rows, and a content column that does not try to be chrome. The materials are macOS 27 (Golden Gate) Liquid Glass. Apple’s Human Interface Guidelines are the backbone: when a system control, gesture, or behavior exists, use it. Do not repaint Craft’s flat dark slabs, and do not invent a second visual system on top of the system one.

Liquid Glass is the navigation layer. It belongs on the sidebar, the toolbar, menus, popovers, and modals. It does not belong on lists, notes, chat, settings rows, or the page behind them. The system already draws the glass, responds to the Liquid Glass slider (clear through tinted), and falls back when Reduce Transparency is on. Custom backgrounds on those surfaces fight that.

## Principles

1. **One job per view.** Each page answers one question first (what is next, where is this project going, what did we decide). Put the answer at the top, large and plain. Controls come after the answer, not before it.
2. **Rich, not busy.** A richer interface shows more meaning, not more chrome. Prefer one well-made summary (a next-up card, a timeline, a single number with its trend) over a stack of buttons, pills, and toggles the user has to sort through.
3. **Native first.** System controls, system menus, system focus, and system keyboard behavior. A custom draw is allowed only when no system control does the job, and then it follows the same metrics.
4. **Motion explains.** Things move to show where they came from and where they went. Nothing moves for decoration.
5. **Consistent over clever.** The same object is edited, deleted, and pinned the same way everywhere it appears.

## Materials

Two surfaces. Nothing else.

| Surface | Material | What lives there |
| --- | --- | --- |
| Chrome | System Liquid Glass | Sidebar, toolbar, menus, popovers, modals, the toast |
| Content | Opaque solid | Home, projects, tasks, calendar, settings, notes, threads, decisions, chat |

Chrome uses the system material. The sidebar has no custom fill; the window glass shows through. Do not use `.ultraThinMaterial`, `.regularMaterial`, or a hand-rolled blur as a stand-in. Those are the old materials.

Content uses one solid color for the whole column, edge to edge of that column. A grouped container may sit one step lighter (dark) or one step toward white (light) so the group reads as a plate on the page. That plate is opaque. It is not glass, not a gradient, and not a shadow pretending to be depth.

Glass rules:

- One glass layer. Glass does not sample other glass, so do not stack it.
- Do not clip, mask, or put glass inside a scroll view. Clipping kills the effect and leaves a flat puddle.
- Custom glass (`.glassEffect`, `NSGlassEffectView`) is for a control or panel that floats over the page: the toast, the modal panel, toolbar buttons. One floating group per screen.
- Group floating glass controls in one `GlassEffectContainer`.
- The user’s Liquid Glass slider and Reduce Transparency must keep working. If a color is hardcoded to look good only on clear glass, it is wrong.

## Window

**Locked.** Do not replace this with `NavigationSplitView`, a system toolbar, or a standard title bar.

- Hidden title bar. Window background is `WindowGlass` (`NSVisualEffectView`, material `.sidebar`, blending `.behindWindow`).
- `HStack` spacing 0: `SidebarView` | content column.
- Sidebar width is 232, or 0 when collapsed. Animate width. Do not use `NavigationSplitViewVisibility`.
- Content column: 52pt custom bar (sidebar toggle, page icon, page title, page actions), then the solid page card (radius 12, canvas fill, hairline, shadow). Inset 10 trailing and bottom. Leading inset 10 only when the sidebar is collapsed (78pt on the bar so traffic lights stay clear).
- Default size 1180×760.
- Inactive window: sidebar icons dim with `@Environment(\.appearsActive)`. Selected rows stay readable.

## Sidebar

**Locked.** This is the sidebar. Do not rewrite it. Do not swap it for a `List`, a `NavigationSplitView` column, or a system source list. `SidebarView` + `SidebarRow` are the implementation. If a change is not a bug in that file, or a change this document calls for (hover fade, context menu order), it is not allowed.

Structure (`SidebarView`):

- Custom `VStack`, not a system sidebar.
- Top: 52pt clear drag strip (`WindowDragGesture`) so the traffic lights sit on glass.
- Middle: `ScrollView`, no scroll background. Content padded 8 / 8 / 12 (horizontal / top / bottom). Row stack spacing 1.
- Bottom, outside the scroll: Settings, padded 8 horizontal and 12 bottom. Space separates it from the list, not a hairline.
- No custom fill. Glass shows through.

Order, top to bottom:

1. Home (`house`)
2. Workspace label, then Projects (`square.stack`), Tasks (`checklist`), Calendar (`calendar`)
3. Projects label, then pinned projects first, then the rest by name. Omit the whole Projects block when there are none.
4. Settings (`gearshape`), footer

Rows (`SidebarRow`):

- Height 28. Horizontal padding 8. Icon 18×18, 14pt. Gap 8. Label 13 regular, primary, one line.
- Selection / hover: continuous rounded rect, radius 8, `CraftColor.selection` or `CraftColor.hover`.
- Icon: primary when selected, secondary when the window is active, tertiary when it is not. No tile behind the icon.
- Pin: `pin.fill`, 9pt, tertiary, trailing edge. Not a badge.
- Plain buttons. Section labels are 13 semibold, secondary, 20 above / 4 below / 8 inset, no hit testing.

Do not add hover to section labels. Do not move Settings into the scroll. Do not add a divider. Do not change the width, the 52pt drag strip, or the row metrics.

## Toolbar

One row. It names the page and holds the actions for that page.

- Leading: back, when there is somewhere to go back to, then the page title at 20 semibold.
- Trailing: at most one primary button, then view switches (grid, list) if the page has them.
- Primary button is a glass capsule (`.glassEffect(.regular, in: Capsule())`), label 13, padding 10 / 6. A circled plus drawn with a hairline stroke is not a button.
- View switches are a system segmented control or a single glass group. Three loose icons with no grouping are not a control.
- Search, if a page needs it, is the system toolbar search field. It is not a custom rounded rectangle in the scroll view.

The toolbar scrolls away only if the page is a long document and the title is already in the document. Settings, lists, and home keep the toolbar fixed.

## Content

The detail column is a solid page. Background goes to the edges of the column. Text and controls sit in an inset.

Page inset is 32 on the leading and trailing edges, 28 under the toolbar, 28 at the bottom. The reading measure for prose (notes, decisions, chat transcript) caps at 680. Lists and settings groups use the full inset width. They do not float in a narrow centered card unless the content is a single compose field.

Vertical rhythm inside a page:

| Gap | Use |
| --- | --- |
| 4 | Title to its subtitle, or a label to its caption |
| 8 | Icon to label, row content to the next row inside a group |
| 12 | Last control in a group to the group edge; related blocks that are still one idea |
| 24 | Between sections |
| 32 | Page inset; before a page’s first section after the title |

If two things are in the same group, the gap inside is at most half the gap before the next group. A 1px rule is not a substitute for that gap.

Sections are a label, then the content. The label is 13 semibold, primary, 8 below it. No eyebrow, no tracking, no all-caps.

### Lists

A list on the solid page is rows, not cards.

- Row padding 8 vertical, aligned to the page inset.
- Title 13 medium. Subtitle 12 secondary, two lines max. Meta 11 tertiary.
- Icon, if the row has one, is 22 wide, secondary, top-aligned with the title.
- Separation between rows is 12 of space. A hairline is only for a dense index (a long project list) where space would make the page huge. Hairlines run from the text edge, not through the icon, and not past the inset.
- The whole row is the hit target.

### Groups

Settings and any “many properties” block use one plate per group.

- Plate fill is the elevated solid, corner radius 12, continuous.
- Row padding inside the plate: 16 horizontal, 12 vertical.
- Rows inside a plate are split by a hairline inset 16 from both edges.
- Title 13 primary. Optional subtitle 12 secondary, directly under the title, 2 apart.
- Trailing control is a system toggle, picker, or chevron. It vertically centers on the row. It does not wrap.
- Section label sits outside the plate: 24 above the label, 8 from the label to the plate.

Do not put each setting in its own card. Do not put a card inside the plate.

### Documents and chat

The page is the document. No panel around the text.

- Body 15, line height about 1.45. Titles in the document follow the toolbar title. Do not add a second 24pt bold title in the middle of the page.
- Composer is a solid field on the solid page: 12 corner radius, 12 padding, hairline border at the content color’s hairline token. It sticks to the bottom of the column, inset 32, with 14 of padding around it. A hairline may separate it from the transcript because it is pinned chrome on the page, not a section break.
- Chat bubbles, if any, are flat fills using the elevated solid for the assistant and the selection solid for the user. No tails, no shadows, no gradient.

### Folder and card grids

Used when the page is a collection of documents, matching the Craft folder view.

- Month or group label is 13 secondary, aligned to the card’s leading edge, 12 above the row of cards.
- Cards are solid elevated plates, radius 12, gap 16. Fixed preview area, then title 13 semibold, meta 11 secondary.
- Do not fill empty grid cells. Empty space on the trailing side of the window is correct.
- A card is the hit target. No extra border if the fill already separates it from the canvas. A 1px hairline is allowed in light appearance if the elevated fill is too close to the canvas.

## Project column

Threads, notes, and decisions are a source list on the solid page, not a second sidebar.

- Width 250, solid canvas, no glass, no full-height divider. Separate it from the document with the page inset and the list’s own alignment, or with a single inset hairline if the two columns would otherwise merge.
- Same row metrics as the sidebar (28 tall, 8 inset, radius 8) so it feels like a list and not a new component.
- The document to the right keeps the 32 inset and the 680 measure.

## Hero views

A page whose job is “what is happening now” may open with one display header. Today that is Calendar. Home may adopt it later. Lists, settings, and documents never do.

- The header is the answer, not decoration: the day, the number, the state.
- Leading: the primary word in `CraftFont.display` (34 bold), followed by a 7pt circle, baseline-aligned to the word, 4 after it. The dot is the period. Example: “Wed” then the dot. Calendar uses red unless Settings → Appearance → Use accent → Calendar is on.
- Trailing: the supporting figure in 34 regular, tertiary, monospaced digits. Example: “30”.
- 4 below it: a caption line, 13 secondary (“September 2026”).
- 24 below the header, the page’s first control or section.
- At most one hero per page. No gradient, image, or glow behind it. The solid page is the background.

## Summary cards

When one fact matters most on a page (the next event, the current direction), it gets one summary card.

- Elevated solid plate, radius 14, padding 16.
- Leading 3pt bar in the fact’s data color (see Color), full card height minus 16, radius 1.5.
- Line 1: meta, 11 secondary (“Next up · in 45 min”).
- Line 2: title, 15 medium, primary, one line.
- Line 3: detail, 12 secondary (time range, location).
- The whole card is the hit target. Hover lifts the fill to `CraftColor.selection` with the hover fade.
- One summary card per page.

## Type

San Francisco. One family. System text styles, these sizes only:

| Role | Size | Weight |
| --- | --- | --- |
| Hero header (`CraftFont.display`) | 34 | bold (word) / regular (figure) |
| Page title | 20 | semibold |
| Summary card title, document body | 15 | medium / regular |
| Week-strip day number (`CraftFont.dayNumber`) | 15 | medium, monospaced digits |
| Section | 13 | semibold |
| Body, row, sidebar | 13 | regular |
| Row title when it needs emphasis | 13 | medium |
| Subtitle | 12 | regular |
| Calendar event block title | 12 | medium |
| Caption, section hint, meta | 11 | regular |
| Sidebar icon | 14 | regular |

No other sizes. No light weights. The display size is for hero headers only. Use `.monospacedDigit()` wherever numbers sit in a row or tick (times, day numbers, counts). No monospaced face otherwise, except the developer context preview, which is 11 monospaced and clearly a debug surface.

Primary text is label primary. Supporting text is secondary. Hints and meta are tertiary. Do not invent gray hexes for text.

## Color

Semantic colors only. The accent is the user’s choice in Settings → Appearance (System follows the Mac, or a standard Apple accent). It is used for the primary action, keyboard focus, a selected control that is not a list row, the hero dot, today’s number, and the calendar now-line. List selection is a neutral fill, not the accent. A settings row, a sidebar row, and a document do not each get their own color.

Neutrals, sRGB:

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| Canvas | `0.141, 0.141, 0.137` | `0.965, 0.965, 0.957` | Content column only |
| Elevated | `0.176, 0.176, 0.176` | `1, 1, 1` | Plates, fields, cards |
| Selection | `0.227, 0.227, 0.220` | `0.88, 0.88, 0.867` | Selected and pressed rows |
| Hover | white 5% | black 4% | Hover on a row with no fill |
| Hairline | white 8% | black 8% | Rules inside a plate, field borders |
| Field | white 4% | white | Text fields on canvas |
| Scrim | black 25% | black 12% | Behind a modal, over the page |

### Data color

Data color is color that carries information the user already assigned elsewhere. Today the only data color is the calendar tint (`CalendarTint.color`, from EventKit, overridable in Settings → Calendar).

- Allowed as: a 3pt leading bar, a 12% fill behind an event block, a 5pt dot in the week strip.
- Text on a tinted fill stays primary / secondary. Do not color text with the tint.
- Nothing else in the app gets decorative color.

Appearance is System, Light, or Dark. Accent is System (the Mac’s control accent) or one of the standard Apple accents, set in Settings → Appearance. The accent drives the primary action, keyboard focus, the hero dot, today’s number, and the calendar now-line.

## Controls

Use the system control. A custom draw is allowed only when no system control exists.

- Buttons: system. Primary is the default action. Secondary is plain or bordered. Destructive is the destructive role, and only in a confirmation.
- Toggles: system switch.
- Pickers: system menu.
- Segmented appearance control: system picker, inset in the plate.
- Text fields: plain field inside the elevated fill, radius 8, padding 10, hairline border. Placeholder is tertiary. The focused field shows the system focus ring in the accent.
- Press feedback is the system highlight. Do not scale the window’s contents.

Hit targets are at least 28 on a side. Sidebar rows already are. Icon-only toolbar buttons use the system toolbar item size, not a 16pt glyph with no padding. When a control has a painted shape (capsule, row, card), that shape is the hit target, not the label.

## Context menus

Every object that can be edited has the same menu, in the same order, everywhere it appears (sidebar, project column, projects grid, projects list).

1. `Edit…` (`pencil`): opens the Edit modal for that object.
2. Object actions, in this order when present: Pin / Unpin (`pin` / `pin.slash`), New Sub-track (`plus`), Archive / Unarchive (`archivebox`), Copy Agent ID (`doc.on.doc`).
3. `Divider()`
4. `Delete` (`trash`), destructive role, followed by a confirmation alert.

Rules:

- Every item has an SF Symbol, using `Label(title, systemImage:)`.
- No inline rename. A row never turns into a text field. Titles are changed in the Edit modal.
- Menu titles use title case and the ellipsis character (`…`) when the item opens a modal.

## Modals

There is one modal presenter for the whole app (`SlateModal`), and every modal goes through it: new project, new event, edit event, new reminder, edit reminder, save from chat, connect Cursor, and every Edit modal. Do not use `.sheet` for these.

Why: on macOS the system sheet drops out of the title bar. With the hidden title bar in this window it reads as a pop. The modal instead rises in place over the page.

Structure:

- The presenter lives once, as an overlay on `RootView`, above the panes and below the toast.
- Scrim: the Scrim token, full window, fades with the panel. Clicking it cancels.
- Panel: Liquid Glass, `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))`. Width 440 for a short form (520 for an event). Padding 20. Centered horizontally, with at least 40 above and below. The panel hugs its content. It never grows past the window minus those 40 insets; the fields scroll when they would.
- On an event, the title and footer stay put. The fields in between scroll. Do not force extra height that leaves empty space above the title or below the footer.
- Shadow: black 20%, radius 30, y 12. This is the only floating shadow in the app.

Layout inside the panel:

- Title, 20 semibold, one line (“Edit Project”, “New Event”). On an event, the title *is* the event name: an editable field in that type. New Event uses “New Event” as the placeholder. There is no second Title field.
- 16 below the title, the fields. Each field is a label (13 semibold) and 8 below it the control. 16 between fields.
- Fields use the elevated solid fill, radius 8, padding 10, hairline border, per Controls. The glass shows only around the fields, never through them.
- Pickers and toggles in a modal sit on a row: label leading, system control trailing, 28 tall.
- Event notes are a fixed-height field that scrolls. Do not let the notes field grow the panel.
- Footer, 20 below the last field: a full-width capsule primary (40 tall, 15 medium, accent fill), then Cancel as a 40-tall elevated capsule. The one exception to “no destructive in a modal”: editing an existing event or reminder may show Delete beside Cancel, because EventKit items have no context menu. It still confirms.
- Event and reminder modals surface parsed actions above the footer: Join meeting (from the item URL, notes, or location) and Open location (Maps, when the location is a place). Each action is a 40-tall row with a trailing arrow.
- A modal button’s hit target is the painted shape, not the label. Put the frame, fill, and `contentShape` on the button’s label. Do not apply them after `Button` — on macOS that leaves only the text clickable.

Behavior:

- Esc cancels (`.keyboardShortcut(.cancelAction)`). Return saves (`.keyboardShortcut(.defaultAction)`). The primary is disabled until the form is valid.
- The first field gets focus when the modal appears (`@FocusState`, set on appear).
- Only one modal at a time. Presenting another replaces the first.
- Contents dismiss through `@Environment(\.modalDismiss)`, not `@Environment(\.dismiss)`, which does nothing outside a system sheet.
- Edits apply to a draft. Nothing is written to the model until the user saves. Cancel discards.

Motion: see Motion. Entry is scale from 0.96 plus opacity. Exit is scale to 0.98 plus opacity.

### Edit modal fields

| Object | Fields |
| --- | --- |
| Project | Name, Icon (`SymbolPicker`), Description, Status (menu picker), Pinned (switch) |
| Chat | Title, Archived (switch) |
| Track | Title, Kind (menu picker), Status (menu picker), Summary |
| Decision | Title, Status (menu picker), Decision, Rationale |
| Note | Title |

Multi-line fields (description, summary, decision, rationale) are `TextField(axis: .vertical)` with `lineLimit(3...6)`. Save trims whitespace and calls the object’s `touch()` (or sets `updatedAt`) when it has one.

## Toasts

- A toast is one line, 12 medium, horizontal padding 12, vertical 7, capsule, one glass effect, 18 from the bottom of the window. It does not stack.
- It enters with opacity plus a 6pt rise using `Motion.snappy`, and leaves with opacity using `Motion.quick`.

## Motion

Motion is system springs, short, and purposeful. Define the tokens once in `PersonalContext/Design/Motion.swift` and use only these:

| Token | Value | Use |
| --- | --- | --- |
| `Motion.snappy` | `.snappy(duration: 0.28)` | Presenting: modals, toast, selection pill, popovers |
| `Motion.quick` | `.easeOut(duration: 0.16)` | Dismissing: modal and toast exit |
| `Motion.smooth` | `.smooth(duration: 0.35)` | Layout: paging, expanding, panes |
| `Motion.hover` | `.easeOut(duration: 0.12)` | Hover fill in and out |

Rules:

- **Hover:** a row’s hover fill fades in and out with `Motion.hover`. It does not move, scale, or change size.
- **Selection:** a selection indicator that moves between siblings (the calendar week strip, a segmented control you draw) slides with `matchedGeometryEffect` and `Motion.snappy`. List selection in the sidebar and project column stays instant.
- **Paging:** content that pages (next week, previous week) uses `.transition(.push(from: .trailing))` or `.leading`, matching the direction, with `Motion.smooth`.
- **Modals:** entry `.scale(0.96).combined(with: .opacity)` with `Motion.snappy`; exit `.scale(0.98).combined(with: .opacity)` with `Motion.quick`. Use an asymmetric transition.
- **Destination changes** (sidebar navigation) are instant. Do not animate the page swap.
- No stagger. No hover scale. No looping or ambient animation (the chat orb is the one exception and lives in its own spec). No bounce above the `.snappy` default.
- **Reduce Motion:** read `@Environment(\.accessibilityReduceMotion)`. When it is on, every transition becomes `.opacity`, and every animation that moves or scales becomes `Motion.quick` opacity only. Nothing slides, scales, or pushes.

## Calendar

The calendar is a hero view. Its job: show what today (or the chosen day) looks like, and what is next.

Top to bottom, inside the page inset:

1. **Hero header.** “Wed” plus the accent dot (the period), with “30” trailing, and the caption “September 2026”. This describes the selected day, not always today.
2. **Week strip**, 24 below. One row, seven days, full inset width.
   - Leading: chevron-left, chevron-right (28×28 plain buttons, secondary). Trailing: a “Today” capsule (elevated fill, hairline, padding 10 / 6, label 13; not glass, because it sits in the scroll view), visible only when the selected day is not today. Its space is reserved so the strip does not shift.
   - Each day cell is equal width, 56 tall: the weekday (11 secondary, “Wed”), then the day number (`CraftFont.dayNumber`), then a row of up to 3 tint dots (5pt, 3 apart), one per distinct calendar with an event that day.
   - Today’s number is the accent color. The selected day sits on a `CraftColor.selection` pill, radius 10, which slides between cells (`matchedGeometryEffect`, `Motion.snappy`). Hover on an unselected cell uses the hover fill with `Motion.hover`.
   - The chevrons page by week. The strip content pushes in from the matching edge (`Motion.smooth`). Paging keeps the same weekday selected.
3. **Next up card**, 24 below, only when the selected day is today and an event is still upcoming or in progress. It follows Summary cards. The meta is “Next up · in 45 min”, or “Now · ends in 20 min” when in progress. Clicking it opens the edit event modal.
4. **All-day and reminders**, 24 below, only when present. Label “All day” (section style). All-day events are rows with the tint bar. Reminders keep their completion toggle and open the edit reminder modal on click.
5. **Timeline**, 24 below.
   - Hours from 8 to 20 by default. It widens to include the earliest start and the latest end of the day’s timed events.
   - Each hour is 48 tall. The hour label (11 tertiary, monospaced digits, “9 AM”) is 44 wide, leading, top-aligned to its hour line. The hour line is a hairline running from the label’s trailing edge plus 8 to the inset edge.
   - Event blocks sit to the right of the labels, positioned by start and end (minimum height 22). Overlapping events split the width into equal columns with a 4 gap.
   - A block: radius 8, the tint at 12% fill, a 3pt tint leading bar, padding 6 / 8. Title 12 medium primary, one line. Time range 11 secondary when the block is 40 tall or more. Hover lifts the fill to 18% with `Motion.hover`. Click opens the edit event modal.
   - When the selected day is today, a now-line: 1pt accent line across the event area, with an 7pt accent dot at its leading edge. It updates every minute (`TimelineView(.everyMinute)`).
   - On first appear for today, scroll so the now-line sits about a third of the way down.
6. **Empty day:** one line, tertiary, “Nothing scheduled.” in place of the timeline.

Keyboard: ← and → move the selected day by one (paging the strip when crossing a week edge), ⌘T returns to today.

Access states (not determined, denied) keep `EventKitAccessLine`.

## Do not

These are the specific ways this screen turns into slop. They are out of spec even if a mock looks “cleaner” with them.

- A custom fill on the sidebar or the toolbar.
- Glass, material, or blur on the content column, a list row, a settings plate, a note, or a chat bubble.
- A full-height hairline as the only thing separating sidebar and page.
- A second sidebar that is also glass.
- Cards around single text rows.
- Gradient meshes, glows, colored shadows, blurred orbs, and accent washes behind text.
- More than one typeface, or a size outside the table.
- All-caps section labels, letter-spacing on labels, and icon tiles (rounded square behind every symbol).
- Empty states with an illustration and a paragraph. One sentence, tertiary, inset with the list.
- Decorative color. If it is not the system accent or data color, it is neutral.
- A system `.sheet` for an app modal, or a modal that appears without its transition.
- Inline rename in a row.
- Hover that moves or scales something.
- Copying Craft’s upgrade card, assistant pill, or tab strip. This app does not have those.
