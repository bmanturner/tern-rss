# Tern RSS _(tern-rss)_

RSS and Atom feeds in a Tern block: headlines, previews, a docked reader, favorites and catch-up.

![The Latest tab: new posts marked with dots, read posts dimmed, and a preview card open under the selected headline](docs/latest.png)

Follow feeds without leaving the terminal. The RSS block shows headlines first and opens a preview when you ask. Articles open in one native reader block docked beside the list: its text and its images are drawn in place. Starred feeds show a toast when they post.

The palette offers **Open RSS** (a block beside the focused pane) and **Open RSS in a new tab** (a block alone in a tab, full width). Both commands exist for every declared block.

## Contents

- [Install](#install)
- [Usage](#usage)
- [Settings](#settings)
- [Privacy](#privacy)
- [Requirements](#requirements)
- [Uninstall](#uninstall)
- [Develop](#develop)
- [Contributing](#contributing)
- [License](#license)

## Install

```sh
tern plugin install github.com/bmanturner/tern-rss
```

- Update: run the same command with `--force`.
- From a local clone: `tern plugin install ./tern-rss`.

Then open the palette and run `New RSS block` or `Open RSS`.

## Usage

On first run the block offers four starter feeds. Press `a`, or paste any site or feed URL, to follow your own.

### Tabs

| Tab | Shows |
| --- | --- |
| Latest | Headlines from every feed. Posts that arrived since you last caught up come first, with `●` and a strong title. A "caught up" line separates them from older posts. Read posts dim in place, so nothing moves under the cursor. The filter (`f`) narrows this tab. |
| ★ Favorites | Headlines from starred feeds only. The filter doesn't apply here. |
| Feeds | Your subscriptions with new-post counts and refresh errors, plus sites Carly is still searching. Star, catch up, group, remove and add feeds here; grouped feeds sit under a header row. |

![The Favorites tab beside the docked reader, which draws an article's text and images in place](docs/reader.png)

### Keys

| Key | Does |
| --- | --- |
| `1` `2` `3`, `tab` / `shift+tab` | Switch tabs |
| `j` `k`, arrows, `g` `G`, `page_up` `page_down` | Move |
| `space` (`→` / `←` to show / hide) | Toggle the preview under the selected headline |
| `enter` or `o` | Open the article in the reader block beside the list; one pane reads every article in place (marks it read) |
| `m` | Mark one post read / unread |
| `shift+r` | Mark the posts this tab shows read, or unread when they all already are |
| `shift+m` | Catch up: everything in this tab (on Feeds, the selected feed) stops being new |
| `u` | Undo the last catch-up (until you switch tabs) |
| `s` (Feeds) | Star a feed: its new posts show a toast |
| `d` twice (Feeds) | Remove a feed |
| `a`, or paste a URL | Add a feed |
| `r` | Refresh every feed now |
| `c` | Ask Carly to find a feed after one wasn't found; `esc` dismisses |
| `f` (Latest) | Edit the filter: read state, groups, then ordered rules |
| `t` (Feeds) | Set the selected feed's group (`t`, since `g` jumps to the top) |
| `e` (Feeds) | Edit the selected feed: its title and its URL, on one line. An empty line leaves both, and a new URL is checked like a new feed before it replaces the old one |

### Counts and catch-up

Counts mean "new since you last caught up", not "everything unread". They reset when you catch up instead of growing. The pane title counts only new posts from starred feeds.

![The Feeds tab: starred feeds with new-post counts and a caught-up feed](docs/feeds.png)

### Finding a feed

A pasted feed URL is followed directly. For a web page, the block tries candidates in this order and follows the first one that parses:

1. The page's `<link rel="alternate">` feeds.
2. Links on the page that look like feeds.
3. Known platforms' feed URLs: YouTube channels and playlists, subreddits, GitHub repos and users, Medium, Bluesky and Mastodon-style `@profiles`.
4. `/feed`, `/rss`, `/feed.xml`, `/rss.xml`, `/atom.xml` and `/index.xml`, at the site root and under the page's path.

Unreachable hosts and bad addresses show their error under the add field. When the host answered but no candidate parsed, the block offers "Ask Carly to find it" (press `c` or click it; `esc` dismisses). Only then does Carly open with the question, look harder, and answer through the plugin's `found` / `not_found` exports. The block then follows the feed and shows a toast, or shows Carly's reason in a toast. A search Carly doesn't finish in 10 minutes also ends with a toast. Starter feeds never go to Carly.

> [!NOTE]
> Asking Carly needs the window and the RSS block to share the plugin data directory. When the RSS block runs on a remote host, Carly isn't asked, and the search ends after 10 minutes with the "Carly didn't finish the search" toast.

### Groups and the filter

A feed's group is one line of text; a feed with none is ungrouped. On Feeds, `t` opens a one-line field with the selected feed's group in it: Enter assigns it, an empty line leaves the group, and a name that isn't taken yet makes a new group. Once any feed is grouped, the Feeds list draws a header row per group and nests that group's feeds under it. Header rows aren't selectable, so selection stays on feed ids. Groups come from the feeds themselves: remove the last feed of a group and the group goes with it.

The filter narrows Latest. `f` opens it, and `esc` or `f` closes it. It is a read-state gate, a group gate and an ordered list of rules. A status line above the headlines always shows what it is doing, with the Latest tab counting only the posts the filter shows:

```text
Filter 1 group in · 1 rule · 4 posts hidden   f edit
```

- **Read state.** The first row steps through every post, unread only, and read only with `space` or `x`. The filter starts at **unread only**, so a reader that already knows what you have read buries what you have not. This is a hard gate: it decides before the groups and the rules do, so "unread only" means unread.
- **Groups.** One row per group, plus an "Every group" row. `space` checks the group under the cursor; the checked groups are a whitelist, and with nothing checked every group is in. `x` excludes a group, which always loses; a group is never both checked and excluded. `space` on "Every group" unchecks every group, which is the same as "all".
- **Rules.** Rows are numbered in the order they are read, each shown as `<n> /pattern/flags  <scope>`. `a` adds a rule (the field opens prefilled with the group under the cursor, when there is one), `d` deletes the selected rule, and `K` / `J` move it up or down in that order. `j` / `k` and the arrows move the cursor.

A rule is one line, and the common case is just a pattern:

```text
/sponsor/                  hide matching posts, everywhere
@frontend /sponsor/        ... in one group only
#Rust Weekly /ads?/i       ... in one feed only (no quoting, spaces are fine)
@frontend keep /rust/      show a matching post again (an exception to a drop)
```

`drop` only has to be written to be explicit; leaving it out means drop. A scope is `@group` or `#feed`, and a feed is named by its title, its address, or its host.

The pattern is a real regular expression, with `i` (caseless), `m` (multiline), `s` (dotall) and `x` (spaced) flags after the closing slash. A pattern that does not compile is refused in the field, with the engine's reason. Patterns see the post's text as it is: the title and the feed's preview.

#### What to write

Every line below is a whole rule, checked against the engine that ships in the package:

| Want | Write | Notes |
| --- | --- | --- |
| Hide sponsored posts anywhere | `/sponsor/i` | `i` covers `Sponsor`, `SPONSOR`, `sponsored` |
| Hide either of two words | `/赞助|推广/` | alternation, no group needed |
| Hide Chinese and English spellings | `/(?:sponsor|广告)/i` | `(?:…)` groups the alternation |
| Hide anything with a price | `/\d{3,}元/` | `\d` digit, `{3,}` three or more |
| Hide posts that start with a marker | `/^(▲|Show HN)/` | `^` anchors to the start of the title |
| Hide posts that end with a word | `/周刊$/` | `$` anchors to the end |
| Hide a word, but not inside a longer one | `/(^| )word( |$)/` | `\b` is not available; see below |
| Hide one feed's ads | `#Rust Weekly /ads?/i` | feed by title; spaces need no quoting |
| Hide a site's promos | `#lobste.rs /promo/` | feed by host also works |
| Hide a whole group's off-topic posts | `@news /^\[OT\]/` | group scope |
| Hide everything except one topic | `keep /rust|zig/i` then `/./` | first match wins, so the exception goes above |
| Hide pricing symbols anywhere | `/[$€£]\d+/` | a class covers several symbols at once |
| Hide post series by number | `/连载\s?\d+/` | `\s` is whitespace, `?` makes it optional |
| Ignore case **and** allow spaces for readability | `/s p o n s o r/ix` | `x` drops whitespace from the pattern |
| Match a literal slash | `/事件\/回顾/` | escape the slash, or the pattern ends early |

The two rules that keep one topic out of an otherwise noisy feed, in the order they must appear:

```text
keep /(rust|zig|lua)/i
/./
```

Two shapes the engine cannot run, both refused under the field rather than failing quietly:

- `\b` and `\B` raise at match time in the vendored engine, so they are rejected when the rule is parsed. Write the boundaries by hand: `/(^| )word( |$)/`.
- A pattern has to be inside `/…/`. A bare `sponsor` is refused with "A rule needs a /pattern/".

Luau ships no regular expressions, and Tern has no dependency manager, so the engine is vendored: `lib/regexp.luau` is [Roblox's luau-regexp](https://github.com/Roblox/luau-regexp) (MIT, from Blockzez), carried in the package and licensed beside it in `lib/regexp.LICENSE`. It is in-process Luau, so the plugin still runs **no programs**. A pattern that backtracks badly can be slow: keep rules simple.

Rules are read in order and the first match decides: `drop` hides the post, `keep` shows it. When no rule matches, the group gate decides. `/./` hides everything, so `keep` rules above it are a whitelist. Catch-up on Latest covers the feeds the group gate keeps; posts a rule hides are caught up with their feed.

The filter belongs to Latest only, so Favorites shows every starred feed as is. Like the feed list, it is shared by every RSS block in this host.

### Refresh and toasts

- Feeds refresh every 15 minutes while any RSS block is open. A background tab is fine.
- The first fetch of a feed never shows a toast.
- Feeds (with their catch-up times), read state (kept 180 days), per-feed caches and Carly hand-off files live in `rss/` in the plugin data directory.

> [!NOTE]
> Favorite and Carly toasts show only while an RSS block is open somewhere in the session.

## Settings

The refresh interval is the kv key `config/block/rss/refresh_minutes` (default 15, at least 5). To change it, edit `~/Library/Application Support/Tern/plugin-data/tern-rss/kv.json`:

```json
{"config/block/rss/refresh_minutes": 30}
```

The value is re-read before each refresh and shared by all RSS blocks.

The Latest filter is edited in the block (`f` on Latest) and lives in `rss/filters.json` in the plugin data directory, where it is hand-editable:

```json
{"version":1,"read":"unread","groups":{"tech":true},"excluded":{},"rules":["#Rust Weekly keep /./","/sponsor/i"]}
```

`read` is `all`, `unread` or `read`, `groups` holds the checked groups, `excluded` the excluded ones, and `rules` the rule lines in the order they are read. A file that doesn't decode is kept as `filters.json.bad` and the filter is off; a rule line that doesn't parse is dropped, with a warning in the log. The filter is shared by every RSS block in this host, like the feed list.

## Privacy

- **Network:** the plugin fetches the feed URLs you follow. While you add a site, it also fetches candidate feed URLs on that site's host and links the page itself points to. Candidates on loopback or private-network addresses are skipped unless the URL you pasted is itself local. Articles you open are fetched and drawn by the reader block; a page it cannot extract opens in Tern's browser instead.
- **Carly:** asked only when you choose "Ask Carly to find it".
- **Nothing else:** no telemetry, no accounts, no sync.

> [!WARNING]
> When you ask Carly, the plugin sends that site to Tern's assistant (`cx:ask_carly`), which uses a model turn and reads the third-party site. Per Tern, Carly has full local access. The plugin's prompt tells Carly to treat the site's content as untrusted data and to only fetch pages and call the plugin's exports, but a prompt can't enforce that. Only ask about sites you trust.

### What it runs and writes

- **Network:** each feed URL with `tern.fetch`, every refresh interval while an RSS block is open. Requests are conditional (`If-None-Match` / `If-Modified-Since`), at most 4 at a time, with a 20 s timeout; bodies over 4 MB are rejected. Adding a site also fetches its feed candidates, at most 4 at a time with a 10 s timeout each.
- **Programs:** none.
- **Writes:** in the plugin data directory, `rss/feeds.json` (each feed and its group), `rss/read.json`, `rss/filters.json`, `rss/cache/<feed>.json` and, only after you ask Carly, `rss/carly/<id>.{request,answer,asked,result}.json`; `kv.json` only when config is set. Nothing in the package folder.
- **Reads:** `plugin.toml`, the `blocks/` listing, and the files above.
- **Logs:** warn lines prefixed `tern-rss`.

## Requirements

- Developed and tested on Tern 0.6.1, desktop.
- Uses Carly exports and `ask_carly` (for the optional, ask-first feed search). The browser API is a fallback for pages the native reader cannot extract.
- The plugin's host half runs where the panes run. To use the RSS block in a pane on a remote host, install the plugin on that host too, following Tern's remote-host rules.

## Uninstall

```sh
tern plugin remove tern-rss
```

Your feeds and read state stay in `~/Library/Application Support/Tern/plugin-data/tern-rss/` (macOS). Delete that folder to reset.

## Develop

```sh
git clone https://github.com/bmanturner/tern-rss
cd tern-rss
tern plugin link .     # once; Tern loads the plugin from this folder
tern plugin types .    # writes tern.d.luau (git-ignored) for luau-lsp
tern plugin reload     # explicit reload (saving a file reloads within ~300 ms)
tern plugin list       # status, blocks and load errors
```

Logs: `~/Library/Logs/Tern/tern-daemon.log` (host half: the block, store, polling) and `~/Library/Logs/Tern/tern.log` (window half). Tern drops `tern.log.info` by default, so use `tern.log.warn` while debugging.

### Files

```text
plugin.toml            manifest
host.luau              block registry (host half)
window.luau            palette commands, reader route and pane reuse, Carly route (window half)
blocks/rss.luau        the RSS block; returns its BlockDef
blocks/reader.luau     the native reader block: text and images in document order (host half)
lib/manifest.luau      reads [[blocks]] id/title from plugin.toml      (both halves)
lib/config.luau        typed per-block config over tern.kv             (both halves)
lib/cards.luau         error card + props helper                       (both halves)
lib/poll.luau          pane liveness check                             (host only: tern.pane)
lib/fmt.luau           times, ages, counts, durations, clipping        (both halves)
lib/url.luau           percent-encoding, URL normalize/host/resolve    (both halves)
lib/feed.luau          RSS/Atom/RDF parser, feed candidates, dates     (both halves, pure)
lib/filter.luau        the Latest filter: rules, parser, match test     (both halves, pure)
lib/regexp.luau        vendored regex engine (MIT; see its LICENSE)     (both halves, pure)
lib/carly.luau         find-a-feed hand-off files between the halves   (both halves)
lib/store.luau         feeds, read/catch-up state, caches, polling,
                       toasts, adding with probing, Carly searches     (host only)
docs/                  README screenshots
PRODUCT.md             product brief (users, purpose, principles)
LICENSE                MIT
```

## Contributing

Questions, bug reports and pull requests are welcome in [issues](https://github.com/bmanturner/tern-rss/issues) and [pull requests](https://github.com/bmanturner/tern-rss/pulls). Set up with the [Develop](#develop) steps. Keep every file `--!strict`, and type-check with luau-lsp against the `tern.d.luau` that `tern plugin types .` writes. `lib/regexp.luau` is the one exception: it is vendored third-party code, so leave it as it came, license and all.

## License

[MIT](LICENSE) © 2026 Brendan Turner
