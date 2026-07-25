package Plugins::HitsPlaylist::Library;

# Local library lookups. Raw DBI against the LMS schema, the way LastMix does it,
# rather than the DBIx::Class layer: this runs per artist on a menu tap and the
# ORM overhead is not worth paying.
#
# Schema verified against LMS-Community/slimserver SQL/SQLite/schema_1_up.sql:
#   tracks       id, url, title (blob), titlesearch, album, year, secs, musicbrainz_id
#   contributors id, name (blob), namesearch, musicbrainz_id
#   contributor_track  role, contributor, track
#   albums       id, title (blob), titlesearch, compilation, year, contributor
#
# contributor_track roles: 1 Artist, 2 Composer, 3 Conductor,
#                          4 Band, 5 Album artist, 6 Track artist
# We query 1, 4, 5 and 6 and deliberately skip composer and conductor: on a
# classical or soundtrack record those would drag in every track on the disc.
# Querying all four is what makes featured-artist tracks resolve at all.

use strict;
use warnings;

use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Text;
use Slim::Utils::Unicode;

use Plugins::HitsPlaylist::Matcher qw(normalize_title bare_title is_live_title is_live_album);

use constant ROLES => '1,4,5,6';

my $log = logger('plugin.hitsplaylist');

# Resolve an external artist name to a local contributor id.
#
# Tries exact normalized name, then prefix in either direction, which is what
# handles the drift that bites immediately in real data:
#   "Tom Petty"        vs "Tom Petty and the Heartbreakers"
#   "Prince"           vs "Prince and the Revolution"
#   "Bruce Springsteen" vs "Bruce Springsteen & the E Street Band"
sub find_contributor {
    my ($class, $name) = @_;
    return undef unless $name;

    my $dbh    = Slim::Schema->dbh;
    my $search = Slim::Utils::Text::ignoreCase($name, 1);

    my $sth = $dbh->prepare_cached(q{
        SELECT id, name FROM contributors WHERE namesearch = ? LIMIT 1
    });
    $sth->execute($search);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    return $row->{id} if $row;

    # Prefix match, shortest first so "Tom Petty" prefers the plainest variant.
    $sth = $dbh->prepare_cached(q{
        SELECT id, name, namesearch FROM contributors
        WHERE namesearch LIKE ? ORDER BY length(namesearch) ASC LIMIT 1
    });
    $sth->execute($search . '%');
    $row = $sth->fetchrow_hashref;
    $sth->finish;
    return $row->{id} if $row;

    return undef;
}

# Every track credited to this contributor in any of the roles we care about,
# pre-normalized so the matcher can work on it directly.
sub tracks_for_contributor {
    my ($class, $contributor_id, $library_id) = @_;
    return [] unless $contributor_id;

    my $dbh = Slim::Schema->dbh;

    my $sql = q{
        SELECT DISTINCT
            tracks.id       AS id,
            tracks.url      AS url,
            tracks.title    AS title,
            tracks.year     AS year,
            tracks.secs     AS secs,
            tracks.album    AS album_id,
            albums.title    AS album,
            albums.compilation AS compilation
        FROM contributor_track
        JOIN tracks ON tracks.id = contributor_track.track
        LEFT JOIN albums ON albums.id = tracks.album
    } . ($library_id ? q{
        JOIN library_track ON library_track.library = ? AND library_track.track = tracks.id
    } : '') . q{
        WHERE contributor_track.contributor = ?
          AND contributor_track.role IN (} . ROLES . q{)
          AND tracks.audio = 1
    };

    my $sth = $dbh->prepare_cached($sql);
    $sth->execute($library_id ? ($library_id, $contributor_id) : ($contributor_id));

    my @out;
    while (my $r = $sth->fetchrow_hashref) {
        # title and album are blobs holding UTF-8 bytes.
        my $title = Slim::Utils::Unicode::utf8decode($r->{title} // '');
        my $album = Slim::Utils::Unicode::utf8decode($r->{album} // '');

        push @out, {
            id       => $r->{id},
            url      => $r->{url},
            title    => $title,
            album    => $album,
            album_id => $r->{album_id},
            year     => $r->{year},
            duration => $r->{secs},
            norm     => normalize_title($title),
            stripped => (bare_title($title) ne normalize_title($title)) ? 1 : 0,
            live     => (is_live_title($title) || is_live_album($album)) ? 1 : 0,
            # albums.compilation is a real column and beats guessing from the title,
            # though it flags various-artists records rather than greatest-hits ones,
            # so the title heuristic in the matcher still earns its place.
            compilation => $r->{compilation} ? 1 : 0,
        };
    }
    $sth->finish;

    return \@out;
}

1;
