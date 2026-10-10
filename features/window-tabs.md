# Window tabs

Locked 7 Oct 2026.

Tabs live in the existing 52pt toolbar title slot. One page open looks like today’s title. Two or more become a strip. Spec for the strip is in `DESIGN.md` under Toolbar.

This is not native window tabbing, not a second bar, and not Craft’s tab strip.

## Chrome

- One page: icon + 20 semibold. No box. No ×.
- Two or more: icon + title at 15. Current tab is `CraftColor.selection`, radius 8, semibold, primary. Idle is regular, secondary, no fill.
- Every tab has an icon.
- Close is an × on the tab, always visible while the strip is showing. No motion on hover or press.
- Overflow scrolls horizontally. No visible scroller. Current tab stays in view. At a clipped end the tab pixels themselves blur away; a fully visible first or last tab does not.
- Back and forward sit before the first tab. Each tab keeps its own history. Navigating inside a tab pushes that stack; switching tabs does not. Closing a tab discards its history.
- Trailing page actions stay pinned. Empty space after the tabs still drags the window.
- Drag a tab to reorder. Other tabs slide into the new order while the drag is still down.
- A tab whose chat is generating shows a spinner.
- Hovering a tab shows a small elevated pane: the full title, and if the tab belongs to a project, that project’s icon and name underneath. Not the system tooltip.

## What a tab is

A tab is one main-column view: anything that column can show today (Home, Projects, Tasks, Calendar, Settings, a project, a note, a track, a decision, a chat). It is not a second kind of page.

Two tabs cannot show the same view. Opening something that is already a tab switches to it.

Each tab keeps that view. Switching tabs puts it back on screen, including scroll. Inspector open/closed and sidebar collapsed stay on the window, not on the tab.

The main sidebar follows the current tab. A tab on Membrae highlights Membrae. Switch to Article One and the sidebar highlights Article One.

## How a tab opens

A click in the main sidebar changes the current tab. ⌘-click or **Open in New Tab** in the row’s context menu opens a new tab. If that view is already a tab, switch to it.

A project in the main sidebar is the overview. Click it and the current tab goes to that overview. **Open in New Tab** opens the overview. A chat, note, track, or decision already open for that project is a different tab and stays put.

Project column, Home recents, and other in-app clicks navigate the current tab.

Chat links to notes and other objects open in a new tab. Setting, default on. Turn it off and those links behave like the clicks above.

⌘T opens a generic chat (Quick Ask). It does not belong to the current project.

Closing a tab selects the neighbor to the right, else the one to the left. Closing the last tab goes to Home. Home is then the single page, so the strip goes away.

Open tabs restore on launch, in order.

## Keys

Safari / Chrome pattern:

| Key | Action |
| --- | --- |
| ⌘T | New chat |
| ⌘W | Close current tab |
| ⌘[ | Back in the current tab |
| ⌘] | Forward in the current tab |
| ⌘⇧] or ⌃⇥ | Next tab |
| ⌘⇧[ or ⌃⇧⇥ | Previous tab |
| ⌘1–⌘8 | Jump to that tab |
| ⌘9 | Jump to the last tab |
