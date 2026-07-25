# CLAUDE.md

Rules for working in this repo. These are the things that are **not** obvious from
reading the code, and most of them cost real debugging time to learn. The README
explains what the plugin does; this explains how not to break it.

## Project

**HitsPlaylist** is a Lyrion Music Server (LMS) plugin in Perl. It asks Last.fm
which songs are an artist's hits, matches them against the local library, and
saves a finite playlist. Separate repo, sibling to MobileTranscode. Not part of
LyrPlay and requires zero client-side work.

## Critical rules

1. **`Plugins/HitsPlaylist/Matcher.pm` is GENERATED. Never edit it.**
   The source of truth is `lib/HitsPlaylist/Matcher.pm`, which is what `t/` tests.
   Run `tools/sync-matcher.sh` after any matcher change. `t/compile.t` fails if
   the two drift, because otherwise the shipped code and the tested code diverge
   within a week.

2. **No CPAN dependencies. Ever.** LMS plugins cannot assume anything beyond core
   Perl plus the `Slim::` tree. The matcher deliberately implements its own
   Levenshtein rather than pulling a module. This is also what lets the matcher be
   tested standalone.

3. **All HTTP inside the plugin is async**, via `Slim::Networking::SimpleAsyncHTTP`.
   A blocking fetch in the LMS event loop stalls playback for *every player on the
   server*. Blocking HTTP is allowed in `tools/probe.pl` only, which never runs
   inside LMS. `lib/HitsPlaylist/LastFm.pm` (blocking, probe) and
   `Plugins/HitsPlaylist/LFM.pm` (async, plugin) are separate on purpose. Do not
   merge them.

4. **Never assume a player is selected.** `$client` is undef when browsing from the
   web UI with no player, and whenever a JSON-RPC caller omits the player id. This
   already caused a crash *inside an async HTTP callback*, which killed a
   `Slim::Networking::IO::Select` task rather than failing as a menu error. Browsing
   must work without a player; only actions that play need one.

5. **Never fan out API calls.** Artists are fetched one at a time. Firing a dozen
   concurrent requests at a free API behind one shared key earns a rate limit for
   every user of the plugin. Cost is paid only on a cold cache: measured 2.5s cold,
   0.11s warm.

6. **Resolve artists against the library BEFORE fetching their hits.**
   `find_contributor` is a local indexed lookup; `artist.gettoptracks` is a network
   round trip. Filtering first turns ~30 API calls into ~12.

7. **Do not simplify a matcher rule without checking the song named in its comment.**
   Every rule exists because a specific real song breaks the naive version.
   `(Don't Fear) The Reaper`, `Live and Let Die`, `I Want You to Want Me`,
   `Juicy (Radio Edit)`, `All Too Well (Taylor's version)` are all load-bearing.

8. **Strict matching is deliberate.** A hit you do not own is skipped, and playlists
   come out short and uneven. That is the product, not a defect. What must never
   happen is a *silent* shortfall: when an artist the user explicitly asked for
   contributes nothing, say so.

9. **Never commit personal infrastructure.** Host names, LAN IPs, usernames and
   server paths are environment variables with neutral defaults. See `tools/deploy.sh`.

10. **Never commit probe output.** `probe-*.txt` is gitignored: it contains a real
    person's music library, track by track.

## Traps that have already bitten

Each of these produced a symptom that looked like something else entirely.

- **`use constant` at BEGIN silently overrides a plain `sub` of the same name.**
  A leftover `use constant MAX_PLAYLIST => 40` sat 17 lines below a new
  pref-reading `sub MAX_PLAYLIST` and won. Every read returned 40, the settings
  page was decorative, and **Perl issued no redefinition warning**. `perl -c` was
  clean and the tests passed.

- **`item_id` in `artistinfo` is POSITIONAL.** Attaching a connected player inserts
  `Play / Play Next / Add to End` at the top, shifting every plugin item down.
  A stale index returns a single `Empty` item and looks exactly like a broken
  plugin. Use `tools/drill.sh`, which resolves it dynamically.

- **After an LMS restart, players take ~30s to reconnect.** Until one does,
  `$client` is undef and the action rows are correctly absent. This has twice
  looked like a regression. `tools/deploy.sh` waits for a connected player.

- **XMLBrowser overwrites a feed's title** with the menu item's own name
  (`$opml->{title} = $args->{feedTitle}`). Anything you set as a feed title is
  discarded. Put user-visible counts in an item, not the title.

- **Interpolating a `qr//` into another pattern yields `(?^:...)`,** and the `^`
  resets flags, silently cancelling `/i`. Qualifier patterns are plain strings.

- **`{ ... }` as the final statement of a `map` block parses as a BLOCK, not a
  hashref.** `map` returns a flattened key/value list. Needs a leading `+`.

- **Smart quotes are everywhere in real tag data.** The library stores
  `All Too Well (Taylor's version)` with U+2019. Unicode punctuation is folded to
  ASCII before qualifier matching.

## Workflow

```bash
prove -Ilib t/                       # 43 tests: no network, no LMS, no API key
tools/sync-matcher.sh                # after any matcher change
HOST=my-server LMS_CONTAINER=lms tools/deploy.sh
LMS_HOST=my-server tools/drill.sh <artist_id> [player_mac]
```

**Always deploy with `tools/deploy.sh`.** It gates on compile *and* tests before
copying anything. A hand-rolled `scp` once shipped a non-compiling file; LMS
restarted with a broken plugin and the only symptom was an empty JSON-RPC
response with nothing in the log.

Installing a plugin requires an LMS restart, which interrupts playback on every
player. Check nothing is playing first.

## Verifying match quality

Automated tests cover the rules. They cannot tell you whether the chosen track is
the *right* recording — only a human who knows the music can. Run the probe,
read the table:

```bash
LMS_HOST=my-lms-server perl -Ilib tools/probe.pl --lastfm --top 30
```

Only **wrong matches** are failures. Misses are expected. AMBIG lines are where
several local versions collapsed to one title and one was chosen; those are the
ones worth reading.

The probe and the plugin are independent implementations of the same pipeline.
When they agree on a non-round number, that is real cross-validation. When they
disagree, one of them has a bug — the probe's cache key once omitted the request
limit, so `--top 70` replayed a cached 10-track response and made a plugin cap
look like a library limit.

## Verified against real sources

Checked rather than recalled, with where. Useful when something stops working and
you need to know whether the assumption or the code changed.

| Claim | Source |
|---|---|
| `tracks.titlesearch`, `contributors.namesearch` exist | slimserver `SQL/SQLite/schema_1_up.sql` — the lyrion.org database reference omits them |
| roles 1 Artist, 2 Composer, 3 Conductor, 4 Band, 5 Album artist, 6 Track artist | same schema |
| `albums.compilation` is a real boolean column | same schema |
| `registerInfoProvider` belongs in `postinitPlugin`, not `initPlugin` | LastMix `Plugin.pm:38` |
| enqueue via `playlist playtracks listRef` with plain urls | LastMix `CLI.pm:91` |
| API key convention: `install.xml` `<id2>`, dashes stripped at runtime | LastMix `LFM.pm:22`, `LFM.pm:430` |
| `_pluginDataFor` comes from the base class | slimserver `Slim/Plugin/Base.pm:111` |
| `type => 'link'` may use `url => \&coderef` with `passthrough` | slimserver `Slim/Control/XMLBrowser.pm:471,494` |
| handler signature is `($client, $cb, $args, @passthrough)` | slimserver `Slim/Control/XMLBrowser.pm:525` |
| `is_app => 1` forces the Apps menu | slimserver `Slim/Plugin/OPMLBased.pm:23-26` |
| the release zip needs a top-level `HitsPlaylist/` directory | MobileTranscode-1.3.0.zip |

## Publishing

`repo.xml` points at a GitHub release asset. To cut one:

1. Bump `<version>` in `Plugins/HitsPlaylist/install.xml` **and** in `repo.xml`
2. `tools/sync-matcher.sh`
3. Zip so the archive contains a top-level `HitsPlaylist/` directory
4. `shasum` the zip, put it in `<sha>` in `repo.xml`
5. Create the GitHub release, attach the zip, push `repo.xml` to `main`

The Last.fm API key ships in `install.xml` as `<id2>`, UUID-formatted with the
dashes stripped at runtime. This is the LastMix convention and it means users
register nothing. It is obfuscation, not secrecy: it is public, and Last.fm can
revoke it. The 30-day response cache keeps aggregate traffic low, and users can
supply their own key in settings.

## Open questions

- `artist.getTopTracks` returns **no duration**, which is the strongest signal for
  choosing between versions of a song. Options not yet taken: `track.getInfo` per
  track (10x the traffic), or MusicBrainz via the `mbid` that *is* returned.
- ListenBrainz `/1/popularity/top-recordings-for-artist/{mbid}` needs no API key
  but is MBID-only, so it needs a name-to-MBID step for untagged libraries.
- Classical, soundtracks and compilation-heavy libraries are not handled.
