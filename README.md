# HitsPlaylist

A plugin for [Lyrion Music Server](https://lyrion.org) (formerly Logitech Media
Server) that builds a **finite, saved playlist of an artist's actual hits, drawn
from your own library**.

```
Artist > Hits
    Play all (30 tracks)
    Add to end of queue
    Play all and save as playlist
    Expand with similar artists
    Silver Lining - Mt. Joy
    Dirty Love - Mt. Joy
    ...
```

Last.fm decides which songs are the hits. Your library decides which of those you
actually own. Nothing is streamed and nothing is downloaded.

## Why this exists

Every existing option in this ecosystem has one half of the problem solved:

| | shape | popularity data |
|---|---|---|
| LastMix + Don't Stop The Music | infinite drip, ~5 tracks at a time | Last.fm *similar artists* |
| SQLPlayList / DynamicPlaylists | saved playlists | local metadata only |
| Random Play | shuffle by genre | none |
| MusicIP | acoustic similarity | local analysis |

None of them takes a set of artists and hands you a finite list of their actual
hits. Don't Stop The Music gets closest, but it never gives you an **object** —
you cannot look at what is coming, save it, replay Tuesday's mix on Friday, or
send it to anyone.

## Features

- **Artist > Hits** — that artist's most popular tracks, filtered to what you own
- **Expand with similar artists** — the same, plus artists Last.fm says are alike,
  interleaved so no two consecutive tracks share an artist
- **Hits Basket** — add artists while browsing normally, then build one playlist
  from all of them. `My Music > Hits Playlist`
- Play, append to queue, or save as a named playlist
- Appears in Material, iPeng, the web UI, hardware Squeezeboxes and LyrPlay with
  no client-side work, because it registers through `Slim::Menu::ArtistInfo`

## Install

Add this repository URL in **Settings > Plugins > Additional Repositories**:

```
https raw.githubusercontent.com/mtxmiller/HitsPlaylist/main/repo.xml
```

(as a normal `https://` URL — written with a space above only to keep it out of
link scrapers). Then install **Hits Playlist** from the plugin list and restart.

No Last.fm account or API key is required. One is built in, the same way LastMix
does it. If you would rather use your own, put it in the plugin settings.

## Settings

**Settings > Plugins > Hits Playlist**

| Setting | Default | Notes |
|---|---|---|
| Playlist length | 40 | Strict matching means you may get fewer |
| Similar artists to include | 12 | Counts only artists already in your library |
| When you own several versions | greatest hits | Or prefer the original studio album |
| Last.fm API key | *(blank)* | Optional override of the built-in key |

## Strict by design

If a hit is not in your library it is skipped. Playlists come out short and
uneven, and that is deliberate: a 12-track result means *you own 12 of these*,
not that something failed. When an artist you explicitly asked for contributes
nothing, the plugin says so at the end of the list rather than letting them
silently vanish.

## The interesting part

The API call is 40 lines. **The matcher is the product.**

Given `("Pink Floyd", "Comfortably Numb")` from an external source, find the
right local track in a library that contains the studio cut, a 2011 remaster, and
a live version from *Delicate Sound of Thunder*. Get that wrong and a 40-track
playlist contains the same song three times, and no amount of good popularity
data saves it.

`lib/HitsPlaylist/Matcher.pm` is that logic, with **no LMS and no CPAN
dependencies** so it can be tested standalone and lifted into the plugin
unchanged. Every rule in it names the specific song that breaks the naive
version. Do not simplify a rule without checking its song:

- Strip trailing qualifiers only, never leading ones, or `(Don't Fear) The Reaper`
  becomes `The Reaper` and `(Antichrist Television Blues)` becomes the empty string
- Anchor the qualifier vocabulary, or you destroy `Live and Let Die`,
  `Radio Ga Ga` and `Video Killed the Radio Star`
- Do not blindly prefer studio over live: the canonical `I Want You to Want Me`
  is the *At Budokan* recording, and the same is true of `Show Me the Way` and
  `Free Bird`
- Never token-set fuzzy matching, which is subset-tolerant by construction and
  lets `I Want You` swallow `I Want You Back`
- At two tokens or fewer, demand exact equality: `Home`, `One`, `Numb` are traps

## Development

```bash
prove -Ilib t/                    # 43 tests, no network, no LMS, no API key
tools/sync-matcher.sh             # regenerate the plugin's copy of the matcher
HOST=my-server LMS_CONTAINER=lms tools/deploy.sh
```

`Plugins/HitsPlaylist/Matcher.pm` is **generated** from `lib/HitsPlaylist/Matcher.pm`
by `tools/sync-matcher.sh`, so the tested code and the shipped code cannot drift.
`t/compile.t` enforces both the compile and the sync.

### The probe

`tools/probe.pl` is not the plugin and is deliberately not plugin-shaped. It
prints a MATCH / AMBIG / MISS table for `(artist, title)` pairs against a real
library so a human can read it and spot wrong matches. **You are the oracle** —
no automated test can tell you whether that is the right "I Want You to Want Me".

```bash
LMS_HOST=my-lms-server perl -Ilib tools/probe.pl --lastfm --top 30
```

Only **wrong matches** are failures. Misses are expected. AMBIG means several
local versions collapsed to one title and one was chosen; those are the lines
worth reading.

## Verified, not assumed

Checked against real sources rather than recalled:

| Claim | Source |
|---|---|
| `tracks.titlesearch`, `contributors.namesearch` exist | slimserver `SQL/SQLite/schema_1_up.sql` (the lyrion.org reference page omits them) |
| roles 1 Artist, 2 Composer, 3 Conductor, 4 Band, 5 Album artist, 6 Track artist | same schema |
| `albums.compilation` is a real boolean column | same schema |
| `registerInfoProvider` belongs in `postinitPlugin` | LastMix `Plugin.pm:38` |
| enqueue via `playlist playtracks listRef` with plain urls | LastMix `CLI.pm:91` |
| API key convention: `install.xml` `<id2>`, dashes stripped at runtime | LastMix `LFM.pm:22`, `LFM.pm:430` |
| `_pluginDataFor` comes from the base class | slimserver `Slim/Plugin/Base.pm:111` |
| `type => 'link'` may use `url => \&coderef` with `passthrough` | slimserver `Slim/Control/XMLBrowser.pm:471,494` |
| handler signature is `($client, $cb, $args, @passthrough)` | slimserver `Slim/Control/XMLBrowser.pm:525` |
| `is_app => 1` forces the Apps menu | slimserver `Slim/Plugin/OPMLBased.pm:23-26` |

## Known limitations

- **`artist.getTopTracks` returns no duration.** Duration is the strongest signal
  for picking between several versions of a song, and it is simply not in the
  response. Version selection currently runs on weaker signals: title
  cleanliness, live markers, album cohesion, compilation status, then year.
- Last.fm's ranking is scrobble-weighted, so thin catalogues return junk in the
  top slots (`Untitled`, `Track 01`) which silently becomes a miss.
- Live albums that do not say so anywhere (`Frampton Comes Alive!`,
  `One More From the Road`) cannot be detected from text.
- Classical, soundtracks and heavy compilation libraries are not handled well.

## Credits

The `<id2>` API key convention, the async patterns and the enqueue form were all
learned by reading [LastMix](https://github.com/michaelherger/LastMix) and
[MusicArtistInfo](https://github.com/michaelherger/MusicArtistInfo) by Michael
Herger. The basket exists because DynamicPlaylists4 solved the same
multi-select problem first.

## License

MIT. See [LICENSE](LICENSE).
