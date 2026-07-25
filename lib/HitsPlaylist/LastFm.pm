package HitsPlaylist::LastFm;

# Last.fm client for the PROBE ONLY.
#
# Blocking HTTP and a disk cache, both of which are wrong inside LMS. The plugin
# will use Slim::Networking::SimpleAsyncHTTP and Slim::Utils::Cache instead; a
# blocking fetch in the LMS event loop stalls playback for every player on the
# server. Keep this file out of the plugin.
#
# The API key is read from the environment or ~/.config/hitsplaylist/lastfm.key,
# never from anything inside this repo. Only the API key is needed: getTopTracks
# and getSimilar are unauthenticated, so the shared secret is not used, not
# stored, and not required.

use strict;
use warnings;
use utf8;

use JSON::PP;
use HTTP::Tiny;
use File::Path qw(make_path);
use Exporter 'import';

our @EXPORT_OK = qw(top_tracks similar_artists api_key_available);

my $ENDPOINT  = 'https://ws.audioscrobbler.com/2.0/';
my $CACHE_DIR = "$ENV{HOME}/.cache/hitsplaylist";
my $UA        = HTTP::Tiny->new(
    timeout => 20,
    agent   => 'HitsPlaylist-probe/0.1 (+https://github.com/mtxmiller/HitsPlaylist)',
);

my $KEY;
sub _key {
    return $KEY if $KEY;
    $KEY = $ENV{LASTFM_API_KEY};
    if (!$KEY) {
        my $path = "$ENV{HOME}/.config/hitsplaylist/lastfm.key";
        if (open my $fh, '<', $path) {
            chomp($KEY = <$fh>);
            close $fh;
        }
    }
    die "no Last.fm API key: set LASTFM_API_KEY or write ~/.config/hitsplaylist/lastfm.key\n"
        unless $KEY;
    return $KEY;
}

sub api_key_available {
    my $ok = eval { _key(); 1 };
    return $ok ? 1 : 0;
}

sub _cache_path {
    my ($method, $artist) = @_;
    my $slug = lc $artist;
    $slug =~ s/[^a-z0-9]+/_/g;
    $slug =~ s/\A_+|_+\z//g;
    $slug = substr($slug, 0, 80);
    return "$CACHE_DIR/$method-$slug.json";
}

# Cached forever on disk. Hits data is stable for months, and re-fetching on
# every probe run would be rude to a free API we are not paying for.
sub _get {
    my ($method, $artist, %params) = @_;

    my $path = _cache_path($method, $artist);
    if (open my $fh, '<:encoding(UTF-8)', $path) {
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $data = eval { decode_json($raw) };
        return $data if $data;
    }

    my %q = (
        method      => $method,
        artist      => $artist,
        api_key     => _key(),
        format      => 'json',
        autocorrect => 1,
        %params,
    );
    my $url = $ENDPOINT . '?' . join('&', map { "$_=" . _esc($q{$_}) } sort keys %q);

    my $res = $UA->get($url);
    if (!$res->{success}) {
        # Never let the key reach a log or an error message.
        (my $safe = $url) =~ s/api_key=[^&]*/api_key=REDACTED/;
        die "Last.fm request failed: $res->{status} $res->{reason} ($safe)\n";
    }

    my $data = decode_json($res->{content});
    die "Last.fm error $data->{error}: $data->{message}\n" if $data->{error};

    make_path($CACHE_DIR) unless -d $CACHE_DIR;
    if (open my $fh, '>:encoding(UTF-8)', $path) {
        print $fh JSON::PP->new->canonical->encode($data);
        close $fh;
    }
    return $data;
}

sub _esc {
    my ($s) = @_;
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

# Returns an arrayref of { name, playcount, listeners, mbid, rank }.
# NOTE: getTopTracks does NOT return duration. Verified against the live API.
# Duration is the strongest version-selection signal we have, so it must come
# from elsewhere (track.getInfo, one call per track, or MusicBrainz).
sub top_tracks {
    my ($artist, $limit) = @_;
    $limit ||= 10;

    my $data = _get('artist.gettoptracks', $artist, limit => $limit);
    my $list = $data->{toptracks}{track} || [];
    $list = [$list] if ref $list eq 'HASH';   # single result comes back unwrapped

    my $rank = 0;
    return [ map {
        $rank++;
        {
            name      => $_->{name},
            playcount => $_->{playcount},
            listeners => $_->{listeners},
            mbid      => $_->{mbid},
            rank      => $rank,
        }
    } @$list ];
}

# Returns an arrayref of { name, match, mbid }.
sub similar_artists {
    my ($artist, $limit) = @_;
    $limit ||= 20;

    my $data = _get('artist.getsimilar', $artist, limit => $limit);
    my $list = $data->{similarartists}{artist} || [];
    $list = [$list] if ref $list eq 'HASH';

    return [ map { { name => $_->{name}, match => $_->{match}, mbid => $_->{mbid} } } @$list ];
}

1;
