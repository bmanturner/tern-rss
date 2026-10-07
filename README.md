# Tern RSS _(tern-rss)_

RSS and Atom feeds in a Tern block: headlines, previews, a docked reader, favorites and catch-up.

![The Latest tab: new posts marked with dots, read posts dimmed, and a preview card open under the selected headline](docs/latest.png)

Follow feeds without leaving the terminal. The RSS block shows headlines first and opens a preview when you ask. Articles open in one Tern browser docked beside the list. Starred feeds show a toast when they post.

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
| Latest | Headlines from every feed. Posts that arrived since you last caught up come first, with `●` and a strong title. A "caught up" line separates them from older posts. Read posts dim in place, so nothing moves under the cursor. |
| ★ Favorites | Headlines from starred feeds only. |
| Feeds | Your subscriptions with new-post counts and refresh errors, plus sites Carly is still searching. Star, catch up, remove and add feeds here. |

![The Favorites tab beside the docked reader browser, which shows an open article](docs/reader.png)

### Keys

| Key | Does |
| --- | --- |
| `1` `2` `3`, `tab` / `shift+tab` | Switch tabs |
| `j` `k`, arrows, `g` `G`, `page_up` `page_down` | Move |
| `space` (`→` / `←` to show / hide) | Toggle the preview under the selected headline |
| `enter` or `o` | Open the article in the reader browser beside the block (marks it read) |
| `m` | Mark one post read / unread |
| `shift+m` | Catch up: everything in this tab (on Feeds, the selected feed) stops being new |
| `u` | Undo the last catch-up (until you switch tabs) |
| `s` (Feeds) | Star a feed: its new posts show a toast |
| `d` twice (Feeds) | Remove a feed |
| `a`, or paste a URL | Add a feed |
| `r` | Refresh every feed now |
| `c` | Ask Carly to find a feed after one wasn't found; `esc` dismisses |

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

## Privacy

- **Network:** the plugin fetches the feed URLs you follow. While you add a site, it also fetches candidate feed URLs on that site's host and links the page itself points to. Candidates on loopback or private-network addresses are skipped unless the URL you pasted is itself local. Articles you open load in Tern's browser.
- **Carly:** asked only when you choose "Ask Carly to find it".
- **Nothing else:** no telemetry, no accounts, no sync.

> [!WARNING]
> When you ask Carly, the plugin sends that site to Tern's assistant (`cx:ask_carly`), which uses a model turn and reads the third-party site. Per Tern, Carly has full local access. The plugin's prompt tells Carly to treat the site's content as untrusted data and to only fetch pages and call the plugin's exports, but a prompt can't enforce that. Only ask about sites you trust.

### What it runs and writes

- **Network:** each feed URL with `tern.fetch`, every refresh interval while an RSS block is open. Requests are conditional (`If-None-Match` / `If-Modified-Since`), at most 4 at a time, with a 20 s timeout; bodies over 4 MB are rejected. Adding a site also fetches its feed candidates, at most 4 at a time with a 10 s timeout each.
- **Programs:** none.
- **Writes:** in the plugin data directory, `rss/feeds.json`, `rss/read.json`, `rss/cache/<feed>.json` and, only after you ask Carly, `rss/carly/<id>.{request,answer,asked,result}.json`; `kv.json` only when config is set. Nothing in the package folder.
- **Reads:** `plugin.toml`, the `blocks/` listing, and the files above.
- **Logs:** warn lines prefixed `tern-rss`.

## Requirements

- Developed and tested on Tern 0.6.1, desktop.
- Uses Carly exports and `ask_carly` (for the optional, ask-first feed search) and the browser API (for the docked reader).
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
window.luau            palette commands, reader route, Carly route and exports (window half)
blocks/rss.luau        the RSS block; returns its BlockDef
lib/manifest.luau      reads [[blocks]] id/title from plugin.toml      (both halves)
lib/config.luau        typed per-block config over tern.kv             (both halves)
lib/cards.luau         error card + props helper                       (both halves)
lib/poll.luau          pane liveness check                             (host only: tern.pane)
lib/fmt.luau           times, ages, counts, durations, clipping        (both halves)
lib/url.luau           percent-encoding, URL normalize/host/resolve    (both halves)
lib/feed.luau          RSS/Atom/RDF parser, feed candidates, dates     (both halves, pure)
lib/carly.luau         find-a-feed hand-off files between the halves   (both halves)
lib/store.luau         feeds, read/catch-up state, caches, polling,
                       toasts, adding with probing, Carly searches     (host only)
docs/                  README screenshots
PRODUCT.md             product brief (users, purpose, principles)
LICENSE                MIT
```

## Contributing

Questions, bug reports and pull requests are welcome in [issues](https://github.com/bmanturner/tern-rss/issues) and [pull requests](https://github.com/bmanturner/tern-rss/pulls). Set up with the [Develop](#develop) steps. Keep every file `--!strict`, and type-check with luau-lsp against the `tern.d.luau` that `tern plugin types .` writes.

## License

[MIT](LICENSE) © 2026 Brendan Turner
