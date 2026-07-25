package Plugins::HitsPlaylist::LFM;

# Last.fm client for the PLUGIN. Async only.
#
# This is the in-LMS counterpart to lib/HitsPlaylist/LastFm.pm, which is the
# probe's blocking version. Do not merge them: a blocking HTTP fetch inside the
# LMS event loop stalls playback for every player on the server, which is the
# single most common way plugins break other people's listening.
#
# Responses are cached for 30 days. Hits data is stable for months, so a rebuild
# of the same artist costs nothing and we stay far under any rate limit even
# with one API key shared across all installs.

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant ENDPOINT  => 'https://ws.audioscrobbler.com/2.0/';
use constant CACHE_TTL => 60 * 60 * 24 * 30;   # 30 days

my $log   = logger('plugin.hitsplaylist');
my $prefs = preferences('plugin.hitsplaylist');
my $cache = Slim::Utils::Cache->new();

my $aid;

# The key lives in install.xml as <id2>, UUID-formatted so it reads as an
# identifier rather than a credential. A user-supplied key in prefs wins, for
# anyone who would rather not share the pooled rate limit.
sub aid {
    my ($class, $new) = @_;

    if ($new) {
        $aid = $new;
        $aid =~ s/-//g;
    }

    if (my $own = $prefs->get('apikey')) {
        $own =~ s/[^0-9a-fA-F]//g;
        return $own if length $own == 32;
    }

    return $aid;
}

sub topTracks {
    my ($class, $cb, $ecb, $artist, $limit) = @_;
    $limit ||= 20;

    $class->_call($cb, $ecb, 'artist.gettoptracks', {
        artist => $artist,
        limit  => $limit,
    }, sub {
        my $data = shift;
        my $list = $data->{toptracks}{track} || [];
        $list = [$list] if ref $list eq 'HASH';   # a single result arrives unwrapped

        my $rank = 0;
        return [ map {
            $rank++;
            {
                name      => $_->{name},
                mbid      => $_->{mbid},
                playcount => $_->{playcount},
                rank      => $rank,
            }
        } @$list ];
    });
}

sub similarArtists {
    my ($class, $cb, $ecb, $artist, $limit) = @_;
    $limit ||= 20;

    $class->_call($cb, $ecb, 'artist.getsimilar', {
        artist => $artist,
        limit  => $limit,
    }, sub {
        my $data = shift;
        my $list = $data->{similarartists}{artist} || [];
        $list = [$list] if ref $list eq 'HASH';
        return [ map { { name => $_->{name}, match => $_->{match}, mbid => $_->{mbid} } } @$list ];
    });
}

sub _call {
    my ($class, $cb, $ecb, $method, $params, $parse) = @_;

    my $key = $class->aid();
    if (!$key) {
        $log->error('no Last.fm API key available');
        return $ecb->('no API key');
    }

    my $cacheKey = join('|', 'hitsplaylist', $method, map { "$_=$params->{$_}" } sort keys %$params);
    if (my $cached = $cache->get($cacheKey)) {
        main::DEBUGLOG && $log->is_debug && $log->debug("cache hit: $cacheKey");
        return $cb->($cached);
    }

    my %query = (
        %$params,
        method      => $method,
        api_key     => $key,
        format      => 'json',
        autocorrect => 1,
    );
    my $url = ENDPOINT . '?' . join('&', map { $_ . '=' . uri_escape_utf8($query{$_}) } sort keys %query);

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;

            my $data = eval { from_json($http->content) };
            if ($@ || !$data) {
                $log->error("failed to parse Last.fm response: $@");
                return $ecb->('bad response');
            }
            if ($data->{error}) {
                $log->error("Last.fm error $data->{error}: $data->{message}");
                return $ecb->($data->{message});
            }

            my $parsed = $parse->($data);
            $cache->set($cacheKey, $parsed, CACHE_TTL);
            $cb->($parsed);
        },
        sub {
            my ($http, $error) = @_;
            # Never let the key reach a log line.
            $error =~ s/api_key=[^&\s]*/api_key=REDACTED/g if $error;
            $log->error("Last.fm request failed: $error");
            $ecb->($error);
        },
        {
            timeout => 15,
            cache   => 0,       # we do our own, with a much longer TTL
        }
    )->get($url);
}

1;
