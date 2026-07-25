# HitsPlaylist

An LMS / Lyrion Music Server plugin that builds a **finite, saved playlist** of
artists' actual hits, drawn from your own library.

Existing options in this ecosystem give you one half or the other. LastMix + Don't
Stop The Music drip-feeds five tracks at a time forever and leaves you no artifact.
SQLPlayList and DynamicPlayList save real playlists but only know about local
metadata, never who is actually popular. This joins the two.

**Status: pre-alpha. There is no plugin yet.** See `docs/` in the design doc
referenced below for why that is deliberate.

## Planned surface

```
Artist > Hits Radio           one tap: this artist + similar artists, build and play
Artist > Add to Hits Basket   accumulate artists while browsing, build later
```

Both register through `Slim::Menu::ArtistInfo->registerInfoProvider`, so they appear
in Material, iPeng, the web UI, hardware Squeezeboxes, and LyrPlay without any client
work.

## What actually matters here

The API call is 40 lines. The matcher is the product.

Given `("Pink Floyd", "Comfortably Numb")` from an external source, find the right
local track in a library that contains the studio cut, a 2011 remaster, and a live
version from *Delicate Sound of Thunder*. Get that wrong and a 40 track playlist has
the same song three times, and no amount of good popularity data saves it.

`lib/HitsPlaylist/Matcher.pm` is that logic. It has **no LMS and no CPAN
dependencies**, on purpose: it must lift into the plugin unchanged, and LMS plugins
cannot assume CPAN modules exist. Every rule in it names the specific song that breaks
the naive version. Do not simplify a rule without checking its song.

## The probe

`tools/probe.pl` is not the plugin and is deliberately not plugin-shaped. It prints a
MATCH / AMBIG / MISS table for a list of `(artist, title)` pairs against a real
library, so a human can read it and spot wrong matches. **You are the oracle.** No
automated test can tell you whether that is the right "I Want You to Want Me".

```bash
perl -Ilib tools/probe.pl                     # everything in tools/hits-probe.txt
perl -Ilib tools/probe.pl "Taylor Swift"      # one artist
perl -Ilib tools/probe.pl --host 192.168.1.8
```

It uses blocking HTTP, which is fine because it never runs inside LMS. The plugin will
use `Slim::Networking::SimpleAsyncHTTP`, because a blocking fetch in the LMS event loop
stalls playback for every player on the server.

`tools/hits-probe.txt` holds hand-authored hit lists. These are **not** Last.fm data.
They stand in for it so the matcher can be tuned before any API key exists. Last.fm's
only job is producing `(artist, title)` strings; the matcher never knows where they
came from. When the real API is wired up this file is replaced by its output and
nothing else changes.

## Reading a probe run

Only **wrong matches** are failures. Misses are expected and fine: the plugin is strict
by design, so a hit you do not own is simply skipped and playlists come out short and
uneven. AMBIG means several local versions collapsed to one title and one was chosen;
those are the lines to read.

## Bugs this has already caught

Kept as a record, because each one was invisible until a human read the output:

1. **`qr//` interpolation kills `/i`.** Interpolating a compiled regex into another
   pattern yields `(?^:...)`, and the `^` resets flags to default. Every qualifier
   matched lowercase input only, so `(2011 Remastered Version)` survived while
   `(feat. rob thomas)` was stripped. Qualifiers are plain strings now.
2. **`{ ... }` at the end of a `map` block is a BLOCK, not a hashref.** `map` returned
   a flattened key/value list, and the following sort tried to dereference the string
   `"ants marching"`. Needs a leading `+`.
3. **Smart quotes.** The library stores `All Too Well (Taylor’s version)` with
   U+2019. The qualifier pattern used a straight apostrophe, so nothing stripped.
   Unicode punctuation is now folded to ASCII before qualifier matching.
4. **Title cleanliness was unscored.** `Juicy` and `Juicy (Radio Edit)` both normalize
   to `juicy`, tied on every signal, and the winner was decided by whichever had the
   lower track id. A candidate needing no stripping now scores above one that did.

## Design doc

Full rationale, the landscape survey, the cross-model review, and the complete matcher
specification:

`~/.gstack/projects/lms_streamtest/ericmiller-main-design-20260724-220148.md`

## License

TBD before publishing.
