package HitsPlaylist::Matcher;

# Title matching between external (artist, title) pairs and a local music library.
#
# This module is the product. Everything else in this repo is scaffolding around it.
# It has no LMS dependencies and no CPAN dependencies on purpose: it must be liftable
# into the plugin unchanged, and LMS plugins cannot assume CPAN modules are present.
#
# Every rule here exists because a specific real song breaks the naive version.
# Those songs are named in comments. Do not "simplify" a rule without checking its song.

use strict;
use warnings;
use utf8;

use Unicode::Normalize qw(NFD NFC);
use Exporter 'import';

our @EXPORT_OK = qw(
    normalize_title normalize_artist bare_title
    is_live_title is_live_album similarity
    match_title choose_version dedupe_hits
);

# ---------------------------------------------------------------------------
# Qualifier vocabulary
#
# Only ever applied to a TRAILING bracketed group, or a trailing " - " suffix.
# Never as a substring anywhere in the title, or we destroy:
#   "Live and Let Die", "Live Forever", "Live Wire", "Radio Free Europe",
#   "Radio Ga Ga", "Video Killed the Radio Star", "Mono", "Acoustic #3".
# ---------------------------------------------------------------------------

# NOTE: these are plain STRINGS, not qr// objects, on purpose.
# Interpolating a qr// into another pattern yields (?^:...), and the "^" resets
# flags to default, which silently cancels the /i on the combined regex. That
# bug made every qualifier match lowercase input only, so "(2011 Remastered
# Version)" survived while "(feat. rob thomas)" was stripped. Keep them strings.
my @QUALIFIERS = (
    '\d{4}\s+(?:digital\s+)?remaster(?:ed)?(?:\s+version)?',
    '(?:digital\s+)?remaster(?:ed)?(?:\s+version)?(?:\s+\d{4})?',
    'live(?:\s+(?:at|from|in|on|@)\s+.+)?',
    'live\s+version',
    'demo(?:\s+version)?',
    'mono(?:\s+(?:version|mix))?',
    'stereo(?:\s+(?:version|mix))?',
    'single\s+(?:version|edit|mix)',
    'album\s+version',
    'original\s+(?:version|mix)',
    'radio\s+(?:edit|version|mix)',
    'edit',
    '.*\bremix\b.*',
    '.*\bmix\b',
    'acoustic(?:\s+version)?',
    'unplugged',
    'instrumental',
    'reprise',
    'bonus(?:\s+track)?.*',
    'deluxe.*',
    '\d{4}\s+version',
    're-?record(?:ed|ing)?.*',
    'taylor\'?s\s+version',           # 14 Taylor Swift albums in the test library
    'from\s+the\s+vault',
    'explicit(?:\s+version)?',
    'clean(?:\s+version)?',
    'extended(?:\s+(?:version|mix|play))?',
    'feat\.?\s+.+',
    'featuring\s+.+',
    'ft\.?\s+.+',
);

my $QUALIFIER_RE = do {
    my $alt = join '|', map { "(?:$_)" } @QUALIFIERS;
    qr/\A(?:$alt)\z/i;
};

# Live detection is kept SEPARATE from normalization, because version selection
# needs to know a candidate was live after the marker has been stripped.
# Deliberately not used to reject: the live cut is the canonical hit for
# Cheap Trick "I Want You to Want Me", Frampton "Show Me the Way",
# Kiss "Rock and Roll All Nite", Skynyrd "Free Bird".
my $LIVE_WORD = qr/(?:live|unplugged|in\s+concert)/i;

# TITLES: only a live marker in QUALIFIER POSITION counts, i.e. inside a trailing
# bracketed group or after a " - " suffix. A bare \blive\b anywhere is the same
# substring trap the qualifier vocabulary exists to avoid, and it misfires on
# "Live and Let Die", "Live Forever" (Oasis), "Live Wire" (AC/DC).
sub is_live_title {
    my ($title) = @_;
    return 0 unless defined $title && length $title;
    my $s = _ascii_punct($title);
    return 1 if $s =~ /[\(\[][^\)\]]*\b$LIVE_WORD\b[^\)\]]*[\)\]]/;
    return 1 if $s =~ /\s+-\s+[^-]*\b$LIVE_WORD\b/;
    return 0;
}

# ALBUMS: looser, because live albums rarely mark themselves in qualifier
# position. "Live at Leeds", "Frampton Comes Alive!", "MTV Unplugged" all carry
# the word as free text.
#
# Known false positives, accepted: "Live Through This" (Hole), "Stay Alive".
# The cost of a false positive is only a -200 version-selection penalty, never a
# rejection, so a wrong call here degrades a tie-break rather than losing a track.
sub is_live_album {
    my ($album) = @_;
    return 0 unless defined $album && length $album;
    return _ascii_punct($album) =~ /\b$LIVE_WORD\b/ ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

sub _strip_diacritics {
    my ($s) = @_;
    my $d = NFD($s);
    $d =~ s/\p{M}//g;
    return NFC($d);
}

# Fold Unicode punctuation to ASCII BEFORE qualifier matching.
#
# Found the hard way against the real library: it stores
#   "All Too Well (Taylor\x{2019}s version)"
# with a curly apostrophe. The qualifier pattern used a straight quote, so it
# never fired and the entire qualifier survived into the normalized title.
# Smart quotes, en/em dashes and ellipses are pervasive in real tag data.
sub _ascii_punct {
    my ($s) = @_;
    $s =~ s/[\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}\x{00B4}\x{0060}]/'/g;
    $s =~ s/[\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}]/"/g;
    $s =~ s/[\x{2010}-\x{2015}\x{2212}]/-/g;
    $s =~ s/\x{2026}/.../g;
    $s =~ s/\x{00A0}/ /g;
    return $s;
}

# Strip trailing qualifier groups, repeatedly.
# "Song (Live) (2011 Remaster)" -> "Song"
sub _strip_trailing_qualifiers {
    my ($s) = @_;

    my $changed = 1;
    while ($changed) {
        $changed = 0;

        # Trailing (...) or [...] whose entire contents is a qualifier.
        # Anchored to the END so leading parentheticals survive:
        #   "(Don't Fear) The Reaper", "(I Can't Get No) Satisfaction",
        #   "(Sittin' On) The Dock of the Bay"
        if ($s =~ s/\s*[\(\[]\s*([^\(\)\[\]]+?)\s*[\)\]]\s*\z//) {
            my $inner = $1;
            if ($inner =~ $QUALIFIER_RE) { $changed = 1 }
            else { $s .= " ($inner)"; }   # not a qualifier, put it back
        }

        # Trailing " - Qualifier" form. Very common in scrobble-derived data:
        #   "Comfortably Numb - Live at Earls Court"
        elsif ($s =~ s/\s+-\s+([^-]+?)\s*\z//) {
            my $suffix = $1;
            if ($suffix =~ $QUALIFIER_RE) { $changed = 1 }
            else { $s .= " - $suffix"; }
        }
    }
    return $s;
}

sub normalize_title {
    my ($title) = @_;
    return '' unless defined $title && length $title;

    my $s = _ascii_punct(_strip_diacritics($title));

    my $stripped = _strip_trailing_qualifiers($s);

    # GUARD: never accept a normalization that ate the title.
    # "(Antichrist Television Blues)" would otherwise become the empty string.
    $stripped = $s if $stripped !~ /\S/ || length(_bare($stripped)) < 3;
    $s = $stripped;

    return _bare($s);
}

# The title flattened WITHOUT any qualifier stripping.
# If bare_title eq normalize_title, nothing was stripped, which is a strong
# signal that this is the plain version of the song rather than a variant.
sub bare_title {
    my ($title) = @_;
    return '' unless defined $title && length $title;
    return _bare(_ascii_punct(_strip_diacritics($title)));
}

# Punctuation / spacing / case flattening, shared by title and artist.
sub _bare {
    my ($s) = @_;
    $s = lc $s;
    $s =~ s/\s*&\s*/ and /g;
    $s =~ s/\bn'?\b/ and /g;          # "Rock n Roll" / "Rock 'n' Roll"
    $s =~ s/[^\p{L}\p{N}\s]+/ /g;     # drop punctuation, keep letters/digits
    $s =~ s/\s+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    return $s;
}

# Artist names get the same treatment plus band-name drift handling.
# NOTE: articles are stripped for ARTISTS but never for TITLES.
# "The The" is a band; "The End" is a song and must not become "End".
sub normalize_artist {
    my ($name) = @_;
    return '' unless defined $name && length $name;
    my $s = _bare(_strip_diacritics($name));
    $s =~ s/\Athe\s+//;
    return $s;
}

# Does a Last.fm-style artist string plausibly refer to this local contributor?
# Handles the drift that bites on the very first test artist:
#   "Tom Petty" vs "Tom Petty and the Heartbreakers"
#   "Prince" vs "Prince and the Revolution"
#   "Bruce Springsteen" vs "Bruce Springsteen & the E Street Band"
# And combined credits stored as one contributor row, which really exist in the
# test library: "Pickett, Stephen Cropper, Eddie Floyd"
sub artist_matches {
    my ($wanted, $local) = @_;
    my $w = normalize_artist($wanted);
    my $l = normalize_artist($local);
    return 0 unless length $w && length $l;

    return 1 if $w eq $l;
    return 1 if index($l, $w) == 0 || index($w, $l) == 0;   # prefix drift
    return 1 if $l =~ /(?:\A|[\s,])\Q$w\E(?:[\s,]|\z)/;     # combined credit
    return 0;
}

# ---------------------------------------------------------------------------
# Similarity
#
# Deliberately NOT token-set ratio. Token-set comparison is subset-tolerant by
# construction and returns a perfect score for a pure subset, so it produces:
#   "I Want You"          swallows "I Want You Back"
#   "Love Song"           swallows "Love Song for a Vampire"
#   "Sister"              swallows "Sister Christian"
#   "Empire State of Mind" collapses into "Empire State of Mind (Part II)"
# Levenshtein over the whole string is length-sensitive and does not do that.
# ---------------------------------------------------------------------------

sub _levenshtein {
    my ($a, $b) = @_;
    return length($b) unless length $a;
    return length($a) unless length $b;

    my @prev = (0 .. length($b));
    my @cur;
    my @ac = split //, $a;
    my @bc = split //, $b;

    for my $i (0 .. $#ac) {
        $cur[0] = $i + 1;
        for my $j (0 .. $#bc) {
            my $cost = ($ac[$i] eq $bc[$j]) ? 0 : 1;
            my $min = $prev[$j] + $cost;
            $min = $cur[$j] + 1        if $cur[$j] + 1 < $min;
            $min = $prev[$j + 1] + 1   if $prev[$j + 1] + 1 < $min;
            $cur[$j + 1] = $min;
        }
        @prev = @cur;
    }
    return $prev[-1];
}

sub similarity {
    my ($a, $b) = @_;
    return 0 unless length($a) && length($b);
    return 1 if $a eq $b;
    my $max = length($a) > length($b) ? length($a) : length($b);
    return 1 - (_levenshtein($a, $b) / $max);
}

our $FUZZ_THRESHOLD = 0.90;

# Short titles are the kill zone: "Home", "One", "Alive", "Numb", "Believe",
# "Girl", "You". At <= 2 tokens we demand exact equality and allow no fuzz.
sub _fuzz_allowed {
    my ($norm) = @_;
    my @tokens = split /\s+/, $norm;
    return scalar(@tokens) > 2;
}

# ---------------------------------------------------------------------------
# Matching
#
# @local is an arrayref of hashrefs, each:
#   { id, title, album, album_id, year, duration, norm, live }
# Returns: (status, \@candidates)
#   status: MATCH | AMBIG | MISS
# ---------------------------------------------------------------------------

sub match_title {
    my ($wanted, $local) = @_;

    my $want_norm = normalize_title($wanted);
    return ('MISS', []) unless length $want_norm;

    my @exact = grep { $_->{norm} eq $want_norm } @$local;
    if (@exact) {
        return (scalar(@exact) == 1 ? 'MATCH' : 'AMBIG', \@exact);
    }

    return ('MISS', []) unless _fuzz_allowed($want_norm);

    my @fuzzy;
    for my $t (@$local) {
        next unless length $t->{norm};
        my $score = similarity($want_norm, $t->{norm});
        push @fuzzy, { %$t, score => $score } if $score >= $FUZZ_THRESHOLD;
    }
    return ('MISS', []) unless @fuzzy;

    @fuzzy = sort { $b->{score} <=> $a->{score} } @fuzzy;
    return (scalar(@fuzzy) == 1 ? 'MATCH' : 'AMBIG', \@fuzzy);
}

# ---------------------------------------------------------------------------
# Version selection
#
# Called when several local tracks collapse to one normalized title.
# $ref_duration is optional (seconds); when present it is the STRONGEST signal.
# Year is the weakest: reissues carry the CD year, budget comps carry 0 or 1900
# (which sorts first), greatest-hits comps carry the original single's year.
#
# $preferred_albums is a hashref of album_id => count, from this artist's
# already-resolved hits. Preferring an album that already supplied other hits
# gives consistent mastering and a more coherent playlist.
# ---------------------------------------------------------------------------

sub choose_version {
    my ($candidates, %opt) = @_;
    return undef unless $candidates && @$candidates;
    return $candidates->[0] if @$candidates == 1;

    my $ref_dur   = $opt{ref_duration};
    my $preferred = $opt{preferred_albums} || {};
    my $ref_live  = $opt{ref_live} ? 1 : 0;

    my @scored = map {
        my $c = $_;
        my $s = 0;

        # 1. Duration agreement, +/- 10%. Kills live takes, radio edits, demos
        #    more reliably than any year rule.
        if ($ref_dur && $c->{duration}) {
            my $delta = abs($c->{duration} - $ref_dur) / $ref_dur;
            $s += 1000 if $delta <= 0.10;
            $s -= 500  if $delta >  0.25;
        }

        # 1b. Title cleanliness. A candidate whose raw title needed NO qualifier
        #     stripping is the plain version of the song. Without this, "Juicy"
        #     on Ready to Die and "Juicy (Radio Edit)" on the single both
        #     normalize to "juicy", tie on every other signal, and the winner is
        #     decided by whichever happened to have the lower track id.
        #     Weighted above album cohesion so a clean title beats a variant that
        #     merely sits on an album other hits came from.
        $s += 400 unless $c->{stripped};

        # 2. Live handling. Only penalise live when the reference is NOT live.
        $s -= 200 if $c->{live} && !$ref_live;
        $s += 200 if $c->{live} &&  $ref_live;

        # 3. An album that already supplied other hits by this artist.
        $s += 150 * ($preferred->{ $c->{album_id} // '' } || 0);

        # 4. Non-compilation.
        $s -= 100 if _looks_like_compilation($c->{album});

        # 5. Year, weakest signal, and only when it is not obviously junk.
        if ($c->{year} && $c->{year} > 1900) {
            $s += (2100 - $c->{year}) / 1000;
        }

        # Leading + is required. Without it Perl parses this as a bare BLOCK,
        # not an anonymous hashref, and map returns a flattened key/value list.
        +{ %$c, _score => $s };
    } @$candidates;

    @scored = sort {
        $b->{_score} <=> $a->{_score}
          || ($a->{id} // 0) <=> ($b->{id} // 0)   # deterministic tiebreak
    } @scored;

    return $scored[0];
}

# ---------------------------------------------------------------------------
# Incoming hit-list dedupe
#
# Last.fm's artist.getTopTracks is scrobble-weighted, and listeners scrobble the
# same song under several titles. A real top-10 for The Notorious B.I.G. contains
# "Big Poppa" three times in different disguises; Santana's contains both
# "Smooth (feat. Rob Thomas)" and "Smooth", and both "Black Magic Woman" and
# "Black Magic Woman - Single Version".
#
# Every downstream stage then behaves correctly and still produces a playlist
# with the same song three times. This has to be fixed at the source, before
# matching, or the per-artist quota gets spent on duplicates.
#
# Keeps the FIRST occurrence, which is the highest-ranked one.
# ---------------------------------------------------------------------------

sub dedupe_hits {
    my ($titles) = @_;
    return [] unless $titles && @$titles;

    my (%seen, @out);
    for my $t (@$titles) {
        my $key = normalize_title($t);
        next unless length $key;
        next if $seen{$key}++;
        push @out, $t;
    }
    return \@out;
}

sub _looks_like_compilation {
    my ($album) = @_;
    return 0 unless defined $album;
    return $album =~ /\b(?:greatest\s+hits|best\s+of|the\s+hits|essential|anthology|collection|compilation|now\s+that)\b/i ? 1 : 0;
}

1;
