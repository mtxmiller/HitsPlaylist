#!/usr/bin/env perl

# probe.pl - matcher probe. NOT the plugin, and deliberately not plugin-shaped.
#
# Purpose: print a MATCH / AMBIG / MISS table for a list of (artist, title) pairs
# against a real LMS library, so a human can read it and spot wrong matches.
# The human is the oracle. No automated test can tell you whether that is the
# right "I Want You to Want Me".
#
# Blocking HTTP on purpose. This never runs inside LMS, so the async rule does
# not apply here. The plugin will use Slim::Networking::SimpleAsyncHTTP.
#
# Usage:
#   perl tools/probe.pl                          # all artists
#   perl tools/probe.pl "Taylor Swift"           # one artist
#   perl tools/probe.pl --host 192.168.1.8 --verbose

use strict;
use warnings;
use utf8;
use lib "$ENV{HOME}/dev/HitsPlaylist/lib";

use JSON::PP;
use HTTP::Tiny;
use Getopt::Long;
use FindBin;
use HitsPlaylist::Matcher qw(normalize_title normalize_artist bare_title is_live_title is_live_album match_title choose_version);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $HOST    = '192.168.1.8';
my $PORT    = 9000;
my $FILE    = "$FindBin::Bin/hits-probe.txt";
my $VERBOSE = 0;

GetOptions(
    'host=s'  => \$HOST,
    'port=i'  => \$PORT,
    'file=s'  => \$FILE,
    'verbose' => \$VERBOSE,
) or die "bad options\n";

my $ONLY = shift @ARGV;

# --------------------------------------------------------------------------
# LMS JSON-RPC
# --------------------------------------------------------------------------

my $http = HTTP::Tiny->new(timeout => 20);
my $URL  = "http://$HOST:$PORT/jsonrpc.js";

sub lms {
    my (@cmd) = @_;
    my $body = encode_json({ id => 1, method => 'slim.request', params => [ '', \@cmd ] });
    my $res  = $http->post($URL, { content => $body, headers => { 'Content-Type' => 'application/json' } });
    die "LMS request failed: $res->{status} $res->{reason}\n" unless $res->{success};
    return decode_json($res->{content})->{result};
}

# --------------------------------------------------------------------------
# Load the hits file
# --------------------------------------------------------------------------

sub load_hits {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
    my (@order, %hits, $cur);
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\A\s+|\s+\z//g;
        next if !length $line || $line =~ /\A#/;
        if ($line =~ /\A\[(.+)\]\z/) {
            $cur = $1;
            push @order, $cur;
            $hits{$cur} = [];
        } elsif ($cur) {
            push @{ $hits{$cur} }, $line;
        }
    }
    close $fh;
    return (\@order, \%hits);
}

# --------------------------------------------------------------------------
# Library side
# --------------------------------------------------------------------------

my $ARTIST_CACHE;
sub all_artists {
    return $ARTIST_CACHE if $ARTIST_CACHE;
    my $r = lms('artists', 0, 5000);
    $ARTIST_CACHE = $r->{artists_loop} || [];
    return $ARTIST_CACHE;
}

# Resolve a wanted artist name to a local contributor, tolerating band-name drift.
sub resolve_artist {
    my ($wanted) = @_;
    my $w = normalize_artist($wanted);

    my (@exact, @prefix, @contains);
    for my $a (@{ all_artists() }) {
        my $l = normalize_artist($a->{artist});
        next unless length $l;
        if    ($l eq $w)                                            { push @exact,    $a }
        elsif (index($l, $w) == 0 || index($w, $l) == 0)            { push @prefix,   $a }
        elsif ($l =~ /(?:\A|[\s,])\Q$w\E(?:[\s,]|\z)/)              { push @contains, $a }
    }
    return (@exact)    ? ($exact[0],    'exact')
         : (@prefix)   ? ($prefix[0],   'DRIFT')
         : (@contains) ? ($contains[0], 'COMBINED-CREDIT')
         :               (undef, 'none');
}

sub tracks_for_artist {
    my ($artist_id) = @_;
    # tags: a=artist l=album d=duration y=year e=album_id
    my $r = lms('titles', 0, 2000, "artist_id:$artist_id", 'tags:aldye');
    my @out;
    for my $t (@{ $r->{titles_loop} || [] }) {
        next unless defined $t->{title};
        push @out, {
            id       => $t->{id},
            title    => $t->{title},
            album    => $t->{album},
            album_id => $t->{album_id},
            year     => $t->{year},
            duration => $t->{duration},
            norm     => normalize_title($t->{title}),
            stripped => (bare_title($t->{title}) ne normalize_title($t->{title})) ? 1 : 0,
            live     => (is_live_title($t->{title}) || is_live_album($t->{album} // '')) ? 1 : 0,
        };
    }
    return \@out;
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

sub fmt_track {
    my ($t) = @_;
    my $album = $t->{album} // '?';
    my $year  = ($t->{year} && $t->{year} > 0) ? $t->{year} : '----';
    my $dur   = $t->{duration} ? sprintf('%d:%02d', $t->{duration} / 60, $t->{duration} % 60) : ' -- ';
    return sprintf('%-42s  %-34s %s  %s', _trunc($t->{title}, 42), _trunc($album, 34), $year, $dur);
}

sub _trunc {
    my ($s, $n) = @_;
    $s //= '';
    return length($s) > $n ? substr($s, 0, $n - 1) . "\x{2026}" : $s;
}

my ($order, $hits) = load_hits($FILE);
@$order = grep { lc($_) eq lc($ONLY) } @$order if defined $ONLY;
die "no such artist in $FILE: $ONLY\n" unless @$order;

my %tally = (MATCH => 0, AMBIG => 0, MISS => 0, NOARTIST => 0);
my @review;   # things a human should look at

printf "probe: %s  |  %d artists  |  library %s:%d\n", $FILE, scalar(@$order), $HOST, $PORT;

for my $artist (@$order) {
    my ($local_artist, $how) = resolve_artist($artist);

    print "\n", '=' x 100, "\n";
    if (!$local_artist) {
        printf "%s\n  NOT IN LIBRARY under any recognisable name\n", uc $artist;
        $tally{NOARTIST} += scalar @{ $hits->{$artist} };
        next;
    }

    my $tracks = tracks_for_artist($local_artist->{id});
    printf "%s\n", uc $artist;
    printf "  local contributor: \"%s\" (id %d)  match=%s  tracks=%d\n",
        $local_artist->{artist}, $local_artist->{id}, $how, scalar @$tracks;
    push @review, "artist name drift: wanted \"$artist\", library has \"$local_artist->{artist}\" ($how)"
        if $how ne 'exact';
    print '-' x 100, "\n";

    my %preferred_albums;
    my $rank = 0;

    for my $want (@{ $hits->{$artist} }) {
        $rank++;
        my ($status, $cands) = match_title($want, $tracks);
        $tally{$status}++;

        if ($status eq 'MISS') {
            printf "  %2d %-38s MISS\n", $rank, _trunc($want, 38);
            next;
        }

        my $chosen = choose_version($cands, preferred_albums => \%preferred_albums, ref_live => is_live_title($want));
        $preferred_albums{ $chosen->{album_id} }++ if defined $chosen->{album_id};

        printf "  %2d %-38s %-7s %s\n", $rank, _trunc($want, 38), $status, fmt_track($chosen);

        if ($status eq 'AMBIG') {
            for my $c (@$cands) {
                next if $c->{id} == $chosen->{id};
                printf "  %s %s\n", ' ' x 47, fmt_track($c);
            }
            push @review, sprintf('AMBIG  %s / %s  -> chose "%s" [%s]',
                $artist, $want, $chosen->{title}, $chosen->{album} // '?');
        }
    }
}

# --------------------------------------------------------------------------

my $total = $tally{MATCH} + $tally{AMBIG} + $tally{MISS} + $tally{NOARTIST};
print "\n", '=' x 100, "\n";
printf "TOTALS over %d wanted tracks\n", $total;
printf "  MATCH     %4d  (%.0f%%)   single unambiguous local track\n", $tally{MATCH}, 100 * $tally{MATCH} / ($total || 1);
printf "  AMBIG     %4d  (%.0f%%)   several versions, one chosen - READ THESE\n", $tally{AMBIG}, 100 * $tally{AMBIG} / ($total || 1);
printf "  MISS      %4d  (%.0f%%)   not in library (expected, strict mode)\n", $tally{MISS}, 100 * $tally{MISS} / ($total || 1);
printf "  NOARTIST  %4d  (%.0f%%)   artist absent entirely\n", $tally{NOARTIST}, 100 * $tally{NOARTIST} / ($total || 1);

if (@review) {
    print "\n", '-' x 100, "\nNEEDS HUMAN EYES (", scalar(@review), ")\n";
    print "  $_\n" for @review;
}

print "\nWrong matches are the only real failures. Misses are fine.\n";
