# Window tabs

Locked 7 Oct 2026.

Tabs live in the existing 52pt toolbar title slot. One page open looks like today’s title. Two or more become a strip. Spec for the strip is in `DESIGN.md` under Toolbar.

This is not native window tabbing, not a second bar, and not Craft’s tab strip.

## Chrome

- One page: icon + 20 semibold. No box. No ×.
- Two or more: icon + title at 15. Current tab is `CraftColor.selection`, radius 8, semibold, primary. Idle is regular, secondary, no fill.
- Every tab has an icon.
- Close is an × on the tab, always visible while the strip is showing. No motion on hover or press.
- Overflow scrolls horizontally. No visible scroller. Current tab stays in view.
- Trailing page actions stay pinned. Empty space after the tabs still drags the window.
- Drag a tab to reorder.
- A tab whose chat is generating shows a spinner.

## What a tab is

A tab is one main-column view: anything that column can show today (Home, Projects, Tasks, Calendar, Settings, a project, a note, a track, a decision, a chat). It is not a second kind of page.

Two tabs cannot show the same view. Opening something that is already a tab switches to it.

Each tab keeps that view. Switching tabs puts it back on screen, including scroll. Inspector open/closed and sidebar collapsed stay on the window, not on the tab.

The main sidebar follows the current tab. A tab on Slate highlights Slate. Switch to Article One and the sidebar highlights Article One.

## How a tab opens

Sidebar, project column, Home recents, and other in-app clicks navigate the current tab. They do not add a tab. If that view is already open in another tab, switch to it.

Chat links to notes and other objects open in a new tab. Setting, default on. Turn it off and those links behave like the clicks above.

⌘T opens a new chat (new conversation in the current project, or Quick Ask if there is no project). That is always a new view.

Closing a tab selects the neighbor to the right, else the one to the left. Closing the last tab goes to Home. Home is then the single page, so the strip goes away.

Open tabs restore on launch, in order.

## Keys

Safari / Chrome pattern:

| Key | Action |
| --- | --- |
| ⌘T | New chat |
| ⌘W | Close current tab |
| ⌘⇧] or ⌃⇥ | Next tab |
| ⌘⇧[ or ⌃⇧⇥ | Previous tab |
| ⌘1–⌘8 | Jump to that tab |
| ⌘9 | Jump to the last tab |
