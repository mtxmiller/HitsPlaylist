package Plugins::HitsPlaylist::Plugin;

# HitsPlaylist v0.3.0
#
# Two entry points, one shared pipeline:
#
#   Artist > Hits Radio          seed artist + Last.fm similar artists
#   Artist > Add to Hits Basket  accumulate artists while browsing normally
#   My Music > Hits Playlist     build from whatever is in the basket
#
# Both converge on _buildFromNames: resolve names to local contributors, fetch
# each one's hits, match against the library, interleave by rank.
#
# The basket exists because a true multi-select widget in LMS is miserable
# across web / Material / iPeng / hardware. DynamicPlaylists4 hit the same wall
# and solved it the same way. It stores its preselection in per-client
# pluginData; this uses server prefs instead, so the basket survives a restart
# and works while browsing with no player selected.
#
# The resolved list is shown rather than played blind on purpose. The premise of
# this plugin is that you end up holding an object you can look at, which is the
# thing Don't Stop The Music never gives you.

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Menu::ArtistInfo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::HitsPlaylist::LFM;
use Plugins::HitsPlaylist::Library;
use Plugins::HitsPlaylist::Matcher qw(dedupe_hits match_title choose_version is_live_title);

# Ask for more than we need. Strict mode skips anything not owned, so a top-40
# request routinely yields far fewer, and the deeper ranks are what fill a
# playlist for an artist whose biggest hits happen to be missing.
use constant LASTFM_LIMIT   => 30;   # top tracks requested per artist
use constant SIMILAR_LIMIT  => 30;   # similar artists requested from Last.fm
use constant MAX_ARTISTS    => 12;   # owned artists to build from, similar-expansion
use constant BASKET_MAX_ARTISTS => 25;  # basket is explicit, so allow a bigger set
use constant PER_ARTIST_MAX => 6;    # ceiling per artist before interleaving
use constant MAX_PLAYLIST   => 40;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.hitsplaylist',
    defaultLevel => 'ERROR',
    description  => 'PLUGIN_HITSPLAYLIST_NAME',
});

my $prefs = preferences('plugin.hitsplaylist');

sub initPlugin {
    my $class = shift;

    # The Last.fm key ships in install.xml as <id2>, UUID-formatted.
    Plugins::HitsPlaylist::LFM->aid( $class->_pluginDataFor('id2') );

    Slim::Control::Request::addDispatch(
        ['hitsplaylist', 'play'], [1, 0, 1, \&_cliPlay]
    );
    Slim::Control::Request::addDispatch(
        ['hitsplaylist', 'add'], [1, 0, 1, \&_cliPlay]
    );
    Slim::Control::Request::addDispatch(
        ['hitsplaylist', 'playsave'], [1, 0, 1, \&_cliPlay]
    );

    # menu => 'myMusic' rather than is_app => 1. OPMLBased forces menu='apps'
    # whenever is_app is set (OPMLBased.pm:23-26) and Apps is the streaming
    # service shelf. This plugin never leaves the local library, so it belongs
    # next to Artists / Albums / Playlists where someone would look for it.
    $class->SUPER::initPlugin(
        feed   => \&topLevelFeed,
        tag    => 'hitsplaylist',
        menu   => 'myMusic',
        weight => 80,
    );
}

# ---------------------------------------------------------------------------
# The basket
#
# Stored in server prefs as a plain list of artist NAMES, not contributor ids.
# Ids are reassigned by a full rescan; names survive it, and the name is what
# Last.fm needs anyway.
# ---------------------------------------------------------------------------

sub _basket {
    my $b = $prefs->get('basket');
    return (ref $b eq 'ARRAY') ? $b : [];
}

sub _basketSet {
    my ($list) = @_;
    $prefs->set('basket', $list);
    return $list;
}

sub _basketHas {
    my ($name) = @_;
    return scalar grep { lc $_ eq lc $name } @{ _basket() };
}

# Menu registration goes in postinitPlugin, not initPlugin: info providers are
# collected after every plugin has loaded.
sub postinitPlugin {
    Slim::Menu::ArtistInfo->registerInfoProvider( hitsPlaylistRadio => (
        after => 'top',
        func  => \&artistInfoMenu,
    ) );
}

sub getDisplayName { 'PLUGIN_HITSPLAYLIST_NAME' }

# One call and the item appears in Material, iPeng, the web UI, hardware
# Squeezeboxes and LyrPlay simultaneously. No client code anywhere.
sub artistInfoMenu {
    my ( $client, $url, $artist, $remoteMeta ) = @_;

    my $name = ($artist && $artist->name)
            || (ref $remoteMeta && $remoteMeta->{artist})
            || return;

    my $inBasket = _basketHas($name);

    return [
        {
            name        => cstring($client, 'PLUGIN_HITSPLAYLIST_HITS'),
            type        => 'link',
            url         => \&hitsFeed,
            passthrough => [ { artist => $name } ],
        },
        {
            # The label flips so the same row both adds and removes, which is
            # how you avoid two near-identical entries in an already busy menu.
            name        => $inBasket
                         ? cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_REMOVE')
                         : cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_ADD'),
            type        => 'link',
            url         => \&basketToggle,
            passthrough => [ { artist => $name } ],
        },
    ];
}

sub basketToggle {
    my ( $client, $cb, $args, $pt ) = @_;

    my $name = $pt->{artist} or
        return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_ARTIST') ] });

    my $basket = _basket();

    if ( _basketHas($name) ) {
        _basketSet([ grep { lc $_ ne lc $name } @$basket ]);
        return $cb->({ items => [ {
            type => 'text',
            name => sprintf('%s (%d)', cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_REMOVED'), scalar @{ _basket() }),
        } ] });
    }

    _basketSet([ @$basket, $name ]);
    $cb->({ items => [ {
        type => 'text',
        name => sprintf('%s (%d)', cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_ADDED'), scalar @{ _basket() }),
    } ] });
}

# My Music > Hits Playlist
sub topLevelFeed {
    my ( $client, $cb, $args ) = @_;

    my $basket = _basket();

    if ( !@$basket ) {
        return $cb->({ items => [ {
            type => 'text',
            name => cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_EMPTY'),
        } ] });
    }

    my @items = (
        {
            name        => sprintf('%s (%d)', cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_BUILD'), scalar @$basket),
            type        => 'link',
            url         => \&basketFeed,
            passthrough => [ {} ],
        },
        {
            name        => cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_CLEAR'),
            type        => 'link',
            url         => \&basketClear,
            passthrough => [ {} ],
        },
    );

    # Show what is actually in the basket. Tapping one removes it, so the list
    # doubles as the edit surface and needs no separate management screen.
    push @items, map { {
        name        => $_,
        type        => 'link',
        url         => \&basketToggle,
        passthrough => [ { artist => $_ } ],
    } } @$basket;

    $cb->({ items => \@items });
}

sub basketClear {
    my ( $client, $cb ) = @_;
    _basketSet([]);
    $cb->({ items => [ {
        type => 'text',
        name => cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_CLEARED'),
    } ] });
}

sub basketFeed {
    my ( $client, $cb, $args, $pt ) = @_;

    my $basket = _basket();
    return $cb->({ items => [ {
        type => 'text',
        name => cstring($client, 'PLUGIN_HITSPLAYLIST_BASKET_EMPTY'),
    } ] }) unless @$basket;

    # No similar-artist expansion here: the basket is an explicit choice and
    # padding it with artists the user did not pick would defeat the point.
    # Every basket entry is explicit, so every miss is worth reporting.
    _buildFromNames($client, $cb, 'Basket', $basket, BASKET_MAX_ARTISTS, undef, scalar @$basket);
}

# Artist only. One API call.
#
# Expansion used to be the default and it was the wrong default twice over: the
# basket already covers deliberate multi-artist mixes, and expanding cost 13
# lookups on every tap for someone who just wanted this artist's hits. The
# expand option now lives inside the results, which is where the thought
# "give me more like this" actually occurs.
sub hitsFeed {
    my ( $client, $cb, $args, $pt ) = @_;

    my $seed = $pt->{artist};
    return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_ARTIST') ] })
        unless $seed;

    _buildFromNames($client, $cb, $seed, [ $seed ], 1, $seed, 1);
}

# Reached from the "Expand with similar artists" row inside an artist's hits.
sub expandFeed {
    my ( $client, $cb, $args, $pt ) = @_;

    my $seed = $pt->{artist};
    return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_ARTIST') ] })
        unless $seed;

    # Resolve against the library BEFORE fetching anybody's hits. find_contributor
    # is a local indexed lookup, artist.gettoptracks is a network round trip. On a
    # typical library only a handful of 30 similar artists are owned, so this
    # turns ~30 API calls into ~12.
    Plugins::HitsPlaylist::LFM->similarArtists(
        sub {
            my $similar = shift || [];
            # Only the seed is explicit; the similar artists are suggestions.
            _buildFromNames($client, $cb, $seed,
                [ $seed, map { $_->{name} } @$similar ], MAX_ARTISTS, undef, 1);
        },
        sub {
            my $err = shift;
            $log->error("getSimilar failed for '$seed': " . ($err // 'unknown'));
            _buildFromNames($client, $cb, $seed, [ $seed ], MAX_ARTISTS, undef, 1);
        },
        $seed,
        SIMILAR_LIMIT,
    );
}

# Both entry points land here. Names in, playlist out.
#
# Resolving against the library FIRST is the optimisation that makes expansion
# cheap: find_contributor is a local indexed lookup, artist.gettoptracks is a
# network round trip. Discarding unowned artists before fetching anybody's hits
# turns ~30 API calls into ~12 on a typical library.
sub _buildFromNames {
    my ($client, $cb, $label, $names, $max, $expandSeed, $explicitCount) = @_;

    # The first $explicitCount names are ones the user actually chose: a seed
    # artist, or basket entries. Anything after that is a Last.fm suggestion.
    #
    # The difference matters for reporting. "You added Springsteen and he is not
    # in your library" is worth saying. "Last.fm suggested 26 artists you do not
    # own" is not - that is simply what expansion looks like, and listing them
    # buries the one line that was actually informative.
    $explicitCount = scalar @$names unless defined $explicitCount;

    $max ||= MAX_ARTISTS;

    my @resolved;
    my @notInLibrary;
    my %seen;

    # Order is preserved, so the seed or the basket leads and its hits land
    # first in every round.
    my $idx = -1;
    for my $name (@$names) {
        $idx++;
        last if @resolved >= $max;
        next unless defined $name && length $name;
        next if $seen{ lc $name }++;

        my $contributor = Plugins::HitsPlaylist::Library->find_contributor($name);
        if ( !$contributor ) {
            # Only report a miss the user could have expected to matter.
            push @notInLibrary, $name if $idx < $explicitCount;
            next;
        }

        push @resolved, { name => $name, contributor => $contributor };
    }

    if ( !@resolved ) {
        return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NOT_IN_LIBRARY') ] });
    }

    _fetchHitsSerially($client, $cb, $label, \@resolved, \@notInLibrary, $expandSeed);
}

# One artist at a time, not a fan-out.
#
# Firing a dozen concurrent HTTPS requests at a free API we are not paying for
# is how a plugin earns a rate limit for every user sharing the key. Serial is
# slower only on a cold cache; once warm every call returns synchronously and
# the whole loop is instant.
sub _fetchHitsSerially {
    my ($client, $cb, $label, $artists, $notInLibrary, $expandSeed) = @_;

    my @queue = @$artists;
    my @byArtist;
    my @noHitsOwned;

    # PER_ARTIST_MAX exists to stop one artist dominating an interleaved mix.
    # With a single artist there is nothing to dominate, and capping at 6 makes
    # "Hits" for a well-represented artist look broken. Let it fill the playlist.
    my $perArtist = (scalar @$artists == 1) ? MAX_PLAYLIST : PER_ARTIST_MAX;

    my $next;
    $next = sub {
        my $artist = shift @queue;

        if ( !$artist ) {
            undef $next;               # break the closure cycle
            return _buildFeed($client, $cb, $label, \@byArtist,
                               { missing => $notInLibrary, noHits => \@noHitsOwned },
                               $expandSeed);
        }

        my $collect = sub {
            my $hits = shift || [];
            my $tracks = _matchArtist($artist, $hits, $perArtist);
            if (@$tracks) {
                push @byArtist, { name => $artist->{name}, tracks => $tracks };
            }
            else {
                # In the library, but none of its hits are. Worth saying out
                # loud rather than letting the artist silently vanish.
                push @noHitsOwned, $artist->{name};
            }
            $next->();
        };

        Plugins::HitsPlaylist::LFM->topTracks(
            $collect,
            sub {
                # One artist failing must not abandon the whole playlist.
                $log->error("top tracks failed for '$artist->{name}'");
                $collect->([]);
            },
            $artist->{name},
            LASTFM_LIMIT,
        );
    };

    $next->();
}

# Resolve one artist's hits against the library, in rank order.
sub _matchArtist {
    my ($artist, $hits, $max) = @_;

    $max ||= PER_ARTIST_MAX;

    return [] unless $hits && @$hits;

    my $local = Plugins::HitsPlaylist::Library->tracks_for_contributor($artist->{contributor});
    return [] unless @$local;

    # The API returns the same song under several scrobbled titles.
    my $wanted = dedupe_hits([ map { $_->{name} } @$hits ]);

    my (@tracks, %preferred_albums, %used);

    for my $title (@$wanted) {
        last if @tracks >= $max;

        my ($status, $cands) = match_title($title, $local);
        next if $status eq 'MISS';              # strict: not owned, skip it

        my $track = choose_version($cands,
            preferred_albums => \%preferred_albums,
            ref_live         => is_live_title($title),
        );
        next unless $track;
        next if $used{ $track->{id} }++;

        $preferred_albums{ $track->{album_id} }++ if defined $track->{album_id};
        push @tracks, $track;
    }

    return \@tracks;
}

sub _buildFeed {
    my ($client, $cb, $label, $byArtist, $skipped, $expandSeed) = @_;

    if ( !@$byArtist ) {
        return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_MATCHES') ] });
    }

    # Round-robin by rank: every artist's biggest hit, then every artist's
    # second, and so on. Front-loads the songs people actually know while making
    # it structurally impossible to get six tracks by one artist in a row, which
    # is what plain concatenation gives you and what makes a mix feel broken.
    my (@urls, @items, %usedTrack);
    my $round = 0;

    ROUND: while ( @urls < MAX_PLAYLIST ) {
        my $addedThisRound = 0;

        for my $entry (@$byArtist) {
            next unless $round < scalar @{ $entry->{tracks} };

            my $track = $entry->{tracks}[$round];

            # Cross-artist dedupe: a duet or a cover resolves to one file under
            # two different artists. "Under Pressure" is the canonical case.
            next if $usedTrack{ $track->{id} }++;

            push @urls, $track->{url};
            push @items, {
                name => $track->{title} . ' - ' . $entry->{name},
                type => 'audio',
                url  => $track->{url},
                play => $track->{url},
            };
            $addedThisRound++;

            last ROUND if @urls >= MAX_PLAYLIST;
        }

        last unless $addedThisRound;
        $round++;
    }

    if ( !@urls ) {
        return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_MATCHES') ] });
    }

    # There may be no player: the web UI browses artists without one selected,
    # and any JSON-RPC caller can omit the player id. Browsing the list still
    # works in that case; only playing needs somewhere to play.
    #
    # This is not hypothetical. Without the guard, `artistinfo items` with an
    # empty player id threw inside the async HTTP read callback and took out a
    # Slim::Networking::IO::Select task, which is a far worse failure than a
    # missing menu entry.
    if ($client) {
        # Name reflects what was actually built, not which button was pressed.
        my $playlistName = (scalar @$byArtist > 1)
                         ? "Hits Radio - $label"
                         : "Hits - $label";

        $client->pluginData( hits => {
            artist => $label,
            urls   => \@urls,
            name   => $playlistName,
        } );

        # Counts go HERE, not in the feed title. XMLBrowser overwrites a feed's
        # title with the menu item's own name ($opml->{title} = $args->{feedTitle}),
        # so anything set there is silently discarded. This row is the only place
        # the strict-mode outcome can actually be surfaced, and it matters: a
        # 12-track result should read as "you own 12 of these", not as a bug.
        # Order follows the LMS convention users already know from every other
        # context menu: play, then add to end, then the less common action.
        # Saving is deliberately last; doing it on every run silts up the
        # playlist menu fast.
        unshift @items,
            {
                name        => cstring($client, 'PLUGIN_HITSPLAYLIST_PLAY_ALL')
                             . _countSuffix(scalar @urls, scalar @$byArtist),
                type        => 'link',
                url         => \&playHits,
                passthrough => [ { artist => $label, cmd => 'playtracks', save => 0 } ],
                nextWindow  => 'nowPlaying',
            },
            {
                name        => cstring($client, 'PLUGIN_HITSPLAYLIST_ADD_QUEUE'),
                type        => 'link',
                url         => \&playHits,
                passthrough => [ { artist => $label, cmd => 'addtracks', save => 0 } ],
                # Deliberately NOT nowPlaying: appending should leave you where
                # you are so you can keep browsing and add more.
            },
            {
                name        => cstring($client, 'PLUGIN_HITSPLAYLIST_PLAY_SAVE'),
                type        => 'link',
                url         => \&playHits,
                passthrough => [ { artist => $label, cmd => 'playtracks', save => 1 } ],
                nextWindow  => 'nowPlaying',
            };
    }

    # Offered only on the artist-only view. Sits after the action rows and before
    # the tracks: you have just seen this artist's hits, and that is the moment
    # "give me more like this" occurs to you.
    if ($expandSeed) {
        splice @items, ($client ? 3 : 0), 0, {
            name        => cstring($client, 'PLUGIN_HITSPLAYLIST_EXPAND'),
            type        => 'link',
            url         => \&expandFeed,
            passthrough => [ { artist => $expandSeed } ],
        };
    }

    # Say why the result is smaller than what was asked for.
    #
    # This is the whole reason strict mode is defensible. Without it, asking for
    # four artists and getting three reads as a broken plugin. Last.fm's ranking
    # is also scrobble-weighted, so thin catalogues return junk in the top slots
    # that silently becomes a miss; the user cannot otherwise tell "I don't own
    # it" from "the matcher failed".
    $skipped ||= {};

    # Artists you explicitly asked for that are not in the library at all.
    if ( my @missing = @{ $skipped->{missing} || [] } ) {
        push @items, {
            type => 'text',
            name => cstring($client, 'PLUGIN_HITSPLAYLIST_NOT_OWNED')
                  . ': ' . join(', ', @missing),
        };
    }

    # In the library, but nothing matched. Bounded by the artist cap, and the
    # more interesting of the two: it can mean a thin catalogue OR a matcher
    # miss, and those are worth being able to tell apart.
    if ( my @noHits = @{ $skipped->{noHits} || [] } ) {
        push @items, {
            type => 'text',
            name => cstring($client, 'PLUGIN_HITSPLAYLIST_NO_HITS_OWNED')
                  . ': ' . join(', ', @noHits),
        };
    }

    $cb->({ items => \@items });
}

# One handler for all three rows.
#   $pt->{cmd}  playtracks (replace the queue and play) or addtracks (append)
#   $pt->{save} also write the result out as a named playlist
sub playHits {
    my ( $client, $cb, $args, $pt ) = @_;

    return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_PLAYER') ] })
        unless $client;

    my $data = $client->pluginData('hits') || {};
    my $urls = $data->{urls} || [];

    return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_MATCHES') ] })
        unless @$urls;

    my $cmd = $pt->{cmd} || 'playtracks';
    $client->execute([ 'playlist', $cmd, 'listRef', $urls ]);

    if ( !$pt->{save} ) {
        my $msg = $cmd eq 'addtracks'
                ? cstring($client, 'PLUGIN_HITSPLAYLIST_ADDED')
                : cstring($client, 'PLUGIN_HITSPLAYLIST_PLAYING');

        return $cb->({
            items      => [ { type => 'text', name => sprintf('%s (%d)', $msg, scalar @$urls) } ],
            # Appending should not yank the user to Now Playing.
            $cmd eq 'addtracks' ? () : ( nextWindow => 'nowPlaying' ),
        });
    }

    my $name = $data->{name} || _playlistName($data->{artist});
    $client->execute([ 'playlist', 'save', $name ]);

    $cb->({
        items => [ {
            type => 'text',
            name => cstring($client, 'PLUGIN_HITSPLAYLIST_SAVED') . " \"$name\"",
        } ],
        nextWindow => 'nowPlaying',
    });
}

# Same surface, driven from a control app or a script instead of a menu.
sub _cliPlay {
    my $request = shift;

    my $client = $request->client;
    if ( !$client ) {
        $request->setStatusNeedsClient();
        return;
    }
    if ( $request->isNotCommand([['hitsplaylist'], ['play', 'add', 'playsave']]) ) {
        $request->setStatusBadDispatch();
        return;
    }

    my $data = $client->pluginData('hits') || {};
    my $urls = $data->{urls} || [];

    if ( !@$urls ) {
        $request->addResult('error', 'nothing to play');
        $request->setStatusDone();
        return;
    }

    my $verb = $request->getRequest(1);
    $client->execute([
        'playlist', ($verb eq 'add' ? 'addtracks' : 'playtracks'), 'listRef', $urls
    ]);
    $request->addResult('count', scalar @$urls);

    # Which verb was dispatched decides whether we also save.
    if ( $verb eq 'playsave' ) {
        my $name = $data->{name} || _playlistName($data->{artist});
        $client->execute([ 'playlist', 'save', $name ]);
        $request->addResult('playlist', $name);
    }

    $request->setStatusDone();
}

# The name becomes a filename, so it goes through LMS's filename sanitizer.
# "Hits: Fleetwood Mac" came back as "Hits  Fleetwood Mac" with a double space,
# because the colon is stripped rather than replaced. A hyphen survives intact
# and still sorts every generated playlist together in the menu.
#
# "Hits Radio - X" rather than "Hits - X" because the playlist is no longer just
# X's hits: it is X plus similar artists, and the name should not lie about that.
# "(6 tracks, 1 artists)" reads as a bug even when the number is right.
sub _countSuffix {
    my ($tracks, $artists) = @_;
    return $artists > 1
         ? sprintf(' (%d tracks, %d artists)', $tracks, $artists)
         : sprintf(' (%d tracks)', $tracks);
}

sub _playlistName {
    my ($artist) = @_;
    return 'Hits Radio - ' . ($artist // 'Unknown');
}

sub _errorItem {
    my ($client, $string) = @_;
    return { type => 'text', name => cstring($client, $string) };
}

1;
