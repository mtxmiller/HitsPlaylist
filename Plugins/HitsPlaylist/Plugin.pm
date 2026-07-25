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
use constant LASTFM_LIMIT   => 50;
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

    my $artist = $pt->{artist};
    return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_ARTIST') ] })
        unless $artist;

    Plugins::HitsPlaylist::LFM->topTracks(
        sub { _gotTopTracks($client, $cb, $artist, shift) },
        sub {
            my $err = shift;
            $log->error("Last.fm lookup failed for '$artist': " . ($err // 'unknown'));
            $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_LOOKUP_FAILED') ] });
        },
        $artist,
        LASTFM_LIMIT,
    );
}

sub _gotTopTracks {
    my ($client, $cb, $artist, $hits) = @_;

    if ( !$hits || !@$hits ) {
        return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NO_HITS') ] });
    }

    my $contributor = Plugins::HitsPlaylist::Library->find_contributor($artist);
    if ( !$contributor ) {
        return $cb->({ items => [ _errorItem($client, 'PLUGIN_HITSPLAYLIST_NOT_IN_LIBRARY') ] });
    }

    my $local = Plugins::HitsPlaylist::Library->tracks_for_contributor($contributor);

    # The API returns the same song under several scrobbled titles. Dedupe before
    # matching or the playlist quota gets spent on one song three times over.
    my $wanted = dedupe_hits([ map { $_->{name} } @$hits ]);

    my (@items, @urls, %preferred_albums, %used);

    for my $title (@$wanted) {
        last if @urls >= MAX_PLAYLIST;

        my ($status, $cands) = match_title($title, $local);
        next if $status eq 'MISS';                 # strict: not owned, skip it

        my $track = choose_version($cands,
            preferred_albums => \%preferred_albums,
            ref_live         => is_live_title($title),
        );
        next unless $track;
        next if $used{ $track->{id} }++;           # two titles, one file

        $preferred_albums{ $track->{album_id} }++ if defined $track->{album_id};

        push @urls, $track->{url};
        push @items, {
            name  => $track->{title} . ' - ' . ($track->{album} // ''),
            type  => 'audio',
            url   => $track->{url},
            play  => $track->{url},
        };
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
        # Stash for the play+save command rather than threading 40 urls through
        # a menu action, which jive would have to serialise into the request.
        $client->pluginData( hits => { artist => $artist, urls => \@urls } );

        unshift @items, {
            name        => cstring($client, 'PLUGIN_HITSPLAYLIST_PLAY_SAVE'),
            type        => 'link',
            url         => \&playAndSave,
            passthrough => [ { artist => $artist } ],
            nextWindow  => 'nowPlaying',
        };
    }

    $cb->({
        items => \@items,
        # The header states the strict-mode outcome plainly, so a short playlist
        # reads as "you own 12 of these" rather than as the plugin misbehaving.
        title => cstring($client, 'PLUGIN_HITSPLAYLIST_NAME') . ": $artist ("
               . scalar(@urls) . '/' . scalar(@$wanted) . ')',
    });
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
sub _playlistName {
    my ($artist) = @_;
    return 'Hits - ' . ($artist // 'Unknown');
}

sub _errorItem {
    my ($client, $string) = @_;
    return { type => 'text', name => cstring($client, $string) };
}

1;
