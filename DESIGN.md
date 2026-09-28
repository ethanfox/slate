# Design

The window is glass. The page is solid.

Craft is the layout reference: one sidebar, a quiet toolbar, grouped rows, and a content column that does not try to be chrome. The materials are macOS 27 (Golden Gate) Liquid Glass. Do not repaint Craft’s flat dark slabs, and do not invent a second visual system on top of the system one.

Liquid Glass is the navigation layer. It belongs on the sidebar, the toolbar, menus, popovers, and sheets. It does not belong on lists, notes, chat, settings rows, or the page behind them. The system already draws the glass, responds to the Liquid Glass slider (clear through tinted), and falls back when Reduce Transparency is on. Custom backgrounds on those surfaces fight that and are the current failure.

## Materials

Two surfaces. Nothing else.

| Surface | Material | What lives there |
| --- | --- | --- |
| Chrome | System Liquid Glass | Sidebar, toolbar, menus, popovers, sheets, the toast |
| Content | Opaque solid | Home, projects, tasks, calendar, settings, notes, threads, decisions, chat |

Chrome uses the system material. Do not set a custom fill on `NavigationSplitView`, the sidebar, or the toolbar. Do not hide the toolbar background. Do not use `.ultraThinMaterial`, `.regularMaterial`, or a hand-rolled blur as a stand-in. Those are the old materials.

Content uses one solid color for the whole column, edge to edge of that column. A grouped container may sit one step lighter (dark) or one step toward white (light) so the group reads as a plate on the page. That plate is opaque. It is not glass, not a gradient, and not a shadow pretending to be depth.

Glass rules:

- One glass layer. Glass does not sample other glass, so do not stack it.
- Do not clip, mask, or put glass inside a scroll view. Clipping kills the effect and leaves a flat puddle.
- Custom glass (`.glassEffect`, `NSGlassEffectView`) is for a control that floats over the page: the toast, a floating compose button if one exists. One of those per screen.
- Group floating glass controls in one `GlassEffectContainer`.
- The user’s Liquid Glass slider and Reduce Transparency must keep working. If a color is hardcoded to look good only on clear glass, it is wrong.

## Window

Standard macOS window. Hidden custom chrome is what makes this app look like a fake website.

- `NavigationSplitView`, balanced. The sidebar column is the system sidebar: edge to edge, top to bottom, no inset, no floating card, no rounded island.
- Uniform toolbar across the top. Title, back, and the one primary action live here. Traffic lights stay in the system title area.
- Let the system own the window corner radius. Do not override it.
- Default size stays about 1180×760. The layout has to hold down to a narrow detail column without inventing a second arrangement.
- When the window is inactive, sidebar icons and custom chrome dim with `@Environment(\.appearsActive)`. Selected rows stay readable. Do not leave a full-color sidebar on an inactive window.

The sidebar and the content column meet at the system split. No 1px line drawn by us down that edge.

## Sidebar

Source list. Not a branded panel.

Width 232 ideal, 212 minimum, 300 maximum.

Rows:

- Height 28.
- Selection and hover are a continuous rounded rect, inset 8 from the sidebar edges, corner radius 8.
- Icon column is 18 wide. Gap to the label is 8. Label is 13 regular, one line, tail truncated.
- SF Symbols at regular weight. Color when the window is active, monochrome when it is not. No filled tile behind the icon.
- Selected row: label primary, icon primary. Unselected: label primary, icon secondary. The selection shape carries the state. Do not also recolor the text.

Sections:

- Label is 13 semibold, secondary.
- 20 above a section label, 4 below it, then the rows.
- Rows inside a section are 1 apart. That 1 is air, not a rule.

Order, top to bottom: Home, then Workspace (Projects, Tasks, Calendar), then Projects, then a footer row for Settings separated by space, not a hairline.

Pinned projects sort first. A pin is a 9pt tertiary symbol at the trailing edge, not a badge.

Empty sections do not render a header. “Star docs to keep them close” style hints are allowed only when the section is a real feature with zero items. One line, 11 secondary, inset with the rows.

## Toolbar

One row. It names the page and holds the actions for that page.

- Leading: back, when there is somewhere to go back to, then the page title at 20 semibold.
- Trailing: at most one primary button, then view switches (grid, list) if the page has them.
- Primary button is a system bordered or glass button. A circled plus drawn with a hairline stroke is not a button.
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

## Type

San Francisco. One family. System text styles, these sizes only:

| Role | Size | Weight |
| --- | --- | --- |
| Page title | 20 | semibold |
| Section | 13 | semibold |
| Body, row, sidebar | 13 | regular |
| Row title when it needs emphasis | 13 | medium |
| Document body | 15 | regular |
| Subtitle | 12 | regular |
| Caption, section hint, meta | 11 | regular |
| Sidebar icon | 14 | regular |

No other sizes. No light weights. No monospaced face except the developer context preview, which is 11 monospaced and clearly a debug surface.

Primary text is label primary. Supporting text is secondary. Hints and meta are tertiary. Do not invent gray hexes for text.

## Color

Semantic colors only. The accent is the system accent (the user’s), used for the primary action, keyboard focus, and a selected control that is not a list row. List selection is a neutral fill, not the accent. A settings row, a sidebar row, and a document do not each get their own color.

Neutrals, sRGB:

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| Canvas | `0.141, 0.141, 0.137` | `0.965, 0.965, 0.957` | Content column only |
| Elevated | `0.176, 0.176, 0.176` | `1, 1, 1` | Plates, fields, cards |
| Selection | `0.227, 0.227, 0.220` | `0.88, 0.88, 0.867` | Selected and pressed rows |
| Hover | white 5% | black 4% | Hover on a row with no fill |
| Hairline | white 8% | black 8% | Rules inside a plate, field borders |
| Field | white 4% | white | Text fields on canvas |

Appearance is System, Light, or Dark, and it is the only theme switch. No custom theme previews, no accent-dot row, until those settings actually change something.

## Controls

Use the system control. A custom draw is allowed only when no system control exists.

- Buttons: system. Primary is the default action. Secondary is plain or bordered. Destructive is the destructive role, and only in a confirmation.
- Toggles: system switch.
- Pickers: system menu.
- Segmented appearance control: system picker, inset in the plate.
- Text fields: plain field inside the elevated fill, radius 8, padding 10, hairline border. Placeholder is tertiary.
- Press feedback is the system highlight. Do not scale the window’s contents.

Hit targets are at least 28 on a side. Sidebar rows already are. Icon-only toolbar buttons use the system toolbar item size, not a 16pt glyph with no padding.

## Sheets and toasts

- Sheets are system sheets. They pick up glass from the system. The form inside the sheet is solid content with the same group rules, padding 20, width 440 for a short form.
- A toast is one line, 12 medium, horizontal padding 12, vertical 7, capsule, one glass effect, 18 from the bottom of the window. It does not stack.

## Motion

System motion only. Row highlight and destination changes are instant. A toast may fade in 150ms ease-out. Nothing springs, nothing staggers, nothing moves on hover. Respect Reduce Motion by using the system components that already do.

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
- Decorative color. If it is not the system accent on the primary action, it is neutral.
- Copying Craft’s upgrade card, assistant pill, or tab strip. This app does not have those.
