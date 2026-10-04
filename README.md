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

Everything appears in your normal artist menus, so it works the same in Material,
iPeng, the web interface, hardware Squeezeboxes and LyrPlay.

### Hits, for one artist

Open any artist, then the artist menu. In Material that is the **⋮** button on the
artist page, or long-press / right-click an artist anywhere. Choose **More**, then
**Hits**.

```
Hits
    Play all (30 tracks)          replace the queue and start playing
    Add to end of queue           keep what is playing, add these after
    Play all and save as playlist saves as "Hits - Mt. Joy"
    Expand with similar artists   widen it, see below
    Silver Lining - Mt. Joy
    Dirty Love - Mt. Joy
    ...
```

The list is shown rather than played immediately, so you can see what you are
about to get.

### Expanding to similar artists

Inside that list, **Expand with similar artists** rebuilds it using artists
Last.fm considers similar to this one, limited to artists you already own. Tracks
are interleaved by popularity, so you get everyone's biggest song before anyone's
second, and never several tracks by the same artist in a row.

This is a separate step because it costs about a dozen Last.fm lookups, where
plain **Hits** costs one.

### The Hits Basket, for several artists

To combine artists that Last.fm would not connect on its own:

1. Browse to an artist, open the artist menu, choose **More > Add to Hits Basket**
2. Repeat for as many artists as you like — keep browsing normally in between
3. Go to **My Music > Hits Playlist**
4. Choose **Build from basket**

```
My Music > Hits Playlist
    Build from basket (5)
    Clear basket
    Taylor Swift          tap any artist to remove it
    Mt. Joy
    The Killers
    ...
```

The basket survives a server restart, and it is shared across players rather
than being tied to whichever one you had selected.

### Material Skin

When Material Skin 6.4.6 or later is installed, the plugin adds three entries to
the artist menu, next to **Add to favorites**:

- **Add to Hits Basket** adds the artist. No player is required.
- **Play hits** builds this artist's hits and plays them. A player must be selected.
- **Play hits + similar** does the same, mixed with similar artists you own, like
  **Expand with similar artists**. A player must be selected.

Material shows the entries in three places: the menu on an artist in
**My Music > Artists**, the menu on an artist in search results, and the
actions menu on the artist page.

**More > Hits** is still there. That entry opens the track list. **Play hits**
does not.

## Scripting

Three commands are available from the LMS CLI or JSON-RPC, for scripts, keypads
or home automation. Unlike the menus these are self-contained — give them an
artist and they do the whole job.

```
hitsplaylist basketadd    artist_id:N | artist:NAME
hitsplaylist basketremove artist_id:N | artist:NAME
<playerid> hitsplaylist playhits artist_id:N
<playerid> hitsplaylist playhits artist_id:N add:1     append instead of replace
<playerid> hitsplaylist playhits artist_id:N save:1    also save a playlist
<playerid> hitsplaylist playhits artist_id:N similar:1 mix in similar artists
```

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
