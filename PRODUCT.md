# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

Tern draws block surfaces through its DOM surface protocol; the plugin emits Tern UI nodes, never raw HTML or CSS.

## Users

Public Tern users: developers who live in the Tern terminal and want to follow RSS and Atom feeds without leaving it.

## Product Purpose

Follow RSS/Atom feeds in a native Tern block. Headlines come first, previews open on demand, articles open in Tern's own browser block, and favorite feeds announce new posts with a toast. Success: a user subscribes in seconds, scans what is new at a glance, and never loses their place.

## Positioning

Lives inside Tern as a block. Reading happens in one Tern browser block docked beside the list and reused for every article, so the list stays put while you read.

## Operating Context

- Keyboard-first with pointer support.
- The block lives in a Tern tab and survives window close and daemon restarts.
- Feeds refresh in the background every 15 minutes (configurable, minimum 5) while any RSS block is open; `r` refreshes now.

## Capabilities and Constraints

- RSS 2.0, RSS 1.0 and Atom feeds. A pasted site is searched for its feed (feed links, platform URLs, usual paths); when that fails, the block offers to ask Carly, and Carly is asked only if the user chooses to (a toast reports the result). Starter feeds never go to Carly.
- Not an inbox: counts mean "new since you last caught up" (`shift+m`, undoable), never a growing unread backlog; the pane title counts only new posts from favorite feeds.
- Favorite and Carly toasts only fire while an RSS block is open somewhere in the session.
- Data (feeds, catch-up times, read state, caches, Carly hand-off files) lives in the plugin data directory.
- No accounts or sync.

## Brand Commitments

Inherit Tern's theme. Express meaning with span tokens and tones, never colours.

## Evidence on Hand

- Starter feeds offered on first run: Stencil (`https://stencil.so/rss.xml`), Hacker News (`https://hnrss.org/frontpage`), Lobsters (`https://lobste.rs/rss`), Simon Willison (`https://simonwillison.net/atom/everything/`).
- No testimonials, usage numbers or press; do not fabricate any.

## Product Principles

- Headlines first.
- One key per action.
- Quiet until it matters.
- Never lose your place.
