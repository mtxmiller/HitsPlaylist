# HitsPlaylist

A plugin for [Lyrion Music Server](https://lyrion.org) that builds a playlist of
an artist's biggest songs — from the music you already own.

Pick an artist, get their hits. Nothing is streamed, nothing is downloaded, and
you end up with a real saved playlist rather than an endless shuffle.

```
Mt. Joy > Hits
    Play all (30 tracks)
    Add to end of queue
    Play all and save as playlist
    Expand with similar artists
    Silver Lining - Mt. Joy
    Dirty Love - Mt. Joy
    Sheep - Mt. Joy
    ...
```

## Install

In LMS, go to **Settings > Plugins > Additional Repositories** and add:

```
https://raw.githubusercontent.com/mtxmiller/HitsPlaylist/main/repo.xml
```

Install **Hits Playlist** from the plugin list, then restart the server.

No Last.fm account or API key is needed.

## Using it

Everything appears in your normal artist menu, so it works in Material, iPeng,
the web interface, hardware Squeezeboxes and LyrPlay alike.

**Artist > Hits** — that artist's most popular songs, limited to the ones in your
library. From there you can play them, add them to the end of your queue, or save
them as a playlist.

**Expand with similar artists** — inside that list. Widens the playlist to
include artists Last.fm considers similar, interleaved so you never get several
tracks by the same artist in a row.

**Artist > Add to Hits Basket** — collect artists as you browse. When you are
ready, go to **My Music > Hits Playlist** and build one playlist from all of
them. The basket is remembered between restarts, and tapping an artist in the
list removes it.

## Settings

**Settings > Plugins > Hits Playlist**

| Setting | Default | |
|---|---|---|
| Playlist length | 40 | How many tracks to aim for |
| Similar artists to include | 12 | Only counts artists you already own |
| When you own several versions | Greatest hits | Or prefer the original studio album |
| Last.fm API key | *(blank)* | Optional. Uses a built-in key otherwise |

## Why your playlist might be short

If you do not own one of an artist's hits, it is skipped rather than replaced.
A playlist that comes back with 12 tracks means **you own 12 of these songs** —
it is telling you something about your library, not failing.

If an artist you asked for contributes nothing at all, the plugin says so at the
bottom of the list instead of quietly leaving them out.

## Limitations

- Last.fm ranks by how often songs are scrobbled, so for artists with thin
  catalogues the top of the list can contain oddities like `Untitled` or
  `Track 01`, which simply will not match anything.
- Picking between multiple copies of the same song is imperfect. Last.fm does not
  return track durations, which would be the most reliable way to tell a single
  edit from an album version.
- Live albums that do not announce themselves in their title cannot be detected.
- Classical, soundtrack and compilation-heavy libraries are not handled well.

Tested so far against one library of roughly 10,000 tracks. Reports of what
breaks on yours are welcome in
[Issues](https://github.com/mtxmiller/HitsPlaylist/issues).

## Development

```bash
prove -Ilib t/          # 43 tests. No network, no LMS, no API key needed.
tools/sync-matcher.sh   # after changing the matcher
tools/deploy.sh         # install to a server (see the script for env vars)
```

The song matching lives in `lib/HitsPlaylist/Matcher.pm` and has no LMS or CPAN
dependencies, so it can be tested on its own. `Plugins/HitsPlaylist/Matcher.pm`
is generated from it — edit the copy in `lib/`.

Matching the outside world's idea of a song to a file on your disk is most of the
work here. A library might hold the studio cut of `Comfortably Numb`, a 2011
remaster and a live version, and picking wrong gives you the same song three
times. `tools/probe.pl` prints what the matcher decided for a real library so a
human can check it.

Contributors should read [CLAUDE.md](CLAUDE.md) first: it covers the project
rules and a number of non-obvious traps in the LMS plugin API.

## Credits

Built by reading [LastMix](https://github.com/michaelherger/LastMix) and
[MusicArtistInfo](https://github.com/michaelherger/MusicArtistInfo) by Michael
Herger, which is where the API key convention and the asynchronous patterns come
from. The basket exists because DynamicPlaylists4 solved the same problem first.

## License

MIT. See [LICENSE](LICENSE).
