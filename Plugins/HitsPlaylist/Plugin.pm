package Plugins::HitsPlaylist::Plugin;

# HitsPlaylist v0.1.0 - minimum viable plugin.
#
# Scope is deliberately one menu item: Artist > Hits Radio. No basket, no
# multi-select, no ListenBrainz fallback, no settings beyond an optional API key
# override. The risk in this project was always the matcher, which is now
# validated against 185 real tracks; everything here is plumbing around it.
#
# Flow:
#   Artist > Hits Radio
#     -> Last.fm artist.getTopTracks        (async, cached 30 days)
#     -> dedupe the incoming list           (the API repeats songs)
#     -> match each title to a local track  (Matcher.pm)
#     -> show the resolved list, inspectable, with play + save at the top
#
# The list is shown rather than played blind on purpose. The whole premise of
# this plugin is that you end up holding an object you can look at, which is the
# thing Don't Stop The Music never gives you.

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

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
use constant MAX_ARTISTS    => 12;   # owned artists to actually build from
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
        ['hitsplaylist', 'playsave'], [1, 0, 1, \&_cliPlaySave]
    );

    $class->SUPER::initPlugin(@_);
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

    return [ {
        name        => cstring($client, 'PLUGIN_HITSPLAYLIST_HITS_RADIO'),
        type        => 'link',
        url         => \&hitsFeed,
        passthrough => [ { artist => $name } ],
    } ];
}

sub hitsFeed {
    my ( $client, $cb, $args, $pt ) = @_;

    my $seed = $pt->{artist};
    return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_ARTIST') ] })
        unless $seed;

    # Ask Last.fm who sounds like this artist, then throw away the ones we do
    # not own BEFORE fetching anybody's hits. find_contributor is a local indexed
    # lookup and costs nothing; artist.gettoptracks is a network round trip. On a
    # typical library only a handful of 30 similar artists are owned, so this
    # turns ~30 API calls into ~6.
    Plugins::HitsPlaylist::LFM->similarArtists(
        sub {
            my $similar = shift || [];
            _resolveArtists($client, $cb, $seed, [ map { $_->{name} } @$similar ]);
        },
        sub {
            # No similar-artist data is not fatal: fall back to the seed alone,
            # which is exactly the v0.1 behaviour.
            my $err = shift;
            $log->error("getSimilar failed for '$seed': " . ($err // 'unknown'));
            _resolveArtists($client, $cb, $seed, []);
        },
        $seed,
        SIMILAR_LIMIT,
    );
}

sub _resolveArtists {
    my ($client, $cb, $seed, $similarNames) = @_;

    my @resolved;
    my %seen;

    # Seed artist always leads, so its hits land first in every round.
    for my $name ($seed, @$similarNames) {
        last if @resolved >= MAX_ARTISTS;
        next if $seen{ lc $name }++;

        my $contributor = Plugins::HitsPlaylist::Library->find_contributor($name);
        next unless $contributor;

        push @resolved, { name => $name, contributor => $contributor };
    }

    if ( !@resolved ) {
        return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NOT_IN_LIBRARY') ] });
    }

    _fetchHitsSerially($client, $cb, $seed, \@resolved);
}

# One artist at a time, not a fan-out.
#
# Firing a dozen concurrent HTTPS requests at a free API we are not paying for
# is how a plugin earns a rate limit for every user sharing the key. Serial is
# slower only on a cold cache; once warm every call returns synchronously and
# the whole loop is instant.
sub _fetchHitsSerially {
    my ($client, $cb, $seed, $artists) = @_;

    my @queue = @$artists;
    my @byArtist;

    my $next;
    $next = sub {
        my $artist = shift @queue;

        if ( !$artist ) {
            undef $next;               # break the closure cycle
            return _buildFeed($client, $cb, $seed, \@byArtist);
        }

        my $collect = sub {
            my $hits = shift || [];
            my $tracks = _matchArtist($artist, $hits);
            push @byArtist, { name => $artist->{name}, tracks => $tracks } if @$tracks;
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
    my ($artist, $hits) = @_;

    return [] unless $hits && @$hits;

    my $local = Plugins::HitsPlaylist::Library->tracks_for_contributor($artist->{contributor});
    return [] unless @$local;

    # The API returns the same song under several scrobbled titles.
    my $wanted = dedupe_hits([ map { $_->{name} } @$hits ]);

    my (@tracks, %preferred_albums, %used);

    for my $title (@$wanted) {
        last if @tracks >= PER_ARTIST_MAX;

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
    my ($client, $cb, $seed, $byArtist) = @_;

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
        $client->pluginData( hits => { artist => $seed, urls => \@urls } );

        # Counts go HERE, not in the feed title. XMLBrowser overwrites a feed's
        # title with the menu item's own name ($opml->{title} = $args->{feedTitle}),
        # so anything set there is silently discarded. This row is the only place
        # the strict-mode outcome can actually be surfaced, and it matters: a
        # 12-track result should read as "you own 12 of these", not as a bug.
        unshift @items, {
            name        => cstring($client, 'PLUGIN_HITSPLAYLIST_PLAY_SAVE')
                         . sprintf(' (%d tracks, %d artists)', scalar(@urls), scalar(@$byArtist)),
            type        => 'link',
            url         => \&playAndSave,
            passthrough => [ { artist => $seed } ],
            nextWindow  => 'nowPlaying',
        };
    }

    $cb->({ items => \@items });
}

sub playAndSave {
    my ( $client, $cb, $args, $pt ) = @_;

    return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_PLAYER') ] })
        unless $client;

    my $data = $client->pluginData('hits') || {};
    my $urls = $data->{urls} || [];

    return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_MATCHES') ] })
        unless @$urls;

    my $name = _playlistName($data->{artist});

    $client->execute([ 'playlist', 'playtracks', 'listRef', $urls ]);
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
sub _cliPlaySave {
    my $request = shift;

    my $client = $request->client;
    if ( !$client ) {
        $request->setStatusNeedsClient();
        return;
    }
    if ( $request->isNotCommand([['hitsplaylist'], ['playsave']]) ) {
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

    my $name = _playlistName($data->{artist});
    $client->execute([ 'playlist', 'playtracks', 'listRef', $urls ]);
    $client->execute([ 'playlist', 'save', $name ]);

    $request->addResult('playlist', $name);
    $request->addResult('count', scalar @$urls);
    $request->setStatusDone();
}

# The name becomes a filename, so it goes through LMS's filename sanitizer.
# "Hits: Fleetwood Mac" came back as "Hits  Fleetwood Mac" with a double space,
# because the colon is stripped rather than replaced. A hyphen survives intact
# and still sorts every generated playlist together in the menu.
#
# "Hits Radio - X" rather than "Hits - X" because the playlist is no longer just
# X's hits: it is X plus similar artists, and the name should not lie about that.
sub _playlistName {
    my ($artist) = @_;
    return 'Hits Radio - ' . ($artist // 'Unknown');
}

sub _errorItem {
    my ($client, $string) = @_;
    return { type => 'text', name => cstring($client, $string) };
}

1;
