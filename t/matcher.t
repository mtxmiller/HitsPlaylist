#!/usr/bin/env perl

# Pure unit tests for the matcher. No network, no LMS, no API key.
# Run:  prove -Ilib t/
#
# Every case here is either a rule from the design doc or a bug that actually
# shipped and was caught by reading probe output. Do not delete a case because
# it looks obvious; the obvious ones are the ones that broke.

use strict;
use warnings;
use utf8;

use Test::More;
use lib 'lib';
use HitsPlaylist::Matcher qw(
    normalize_title normalize_artist bare_title
    is_live_title is_live_album similarity
    match_title choose_version
);

binmode(Test::More->builder->$_, ':encoding(UTF-8)')
    for qw(output failure_output todo_output);

# ---------------------------------------------------------------------------
# Normalization: qualifiers that SHOULD be stripped
# ---------------------------------------------------------------------------

my @strip = (
    ['Comfortably Numb (2011 Remastered Version)' => 'comfortably numb'],
    ['Comfortably Numb - Live at Earls Court'     => 'comfortably numb'],
    ['Hey Jude - Remastered 2015'                 => 'hey jude'],
    ['Love Story (Taylor\'s Version)'             => 'love story'],
    ['Smooth (feat. Rob Thomas)'                  => 'smooth'],
    ['Killing In The Name (Explicit)'             => 'killing in the name'],
    ['Something Just Like This (Radio Edit)'      => 'something just like this'],
    ['Juicy (Radio Edit)'                         => 'juicy'],
    ['Big Poppa (club mix)'                       => 'big poppa'],
);
is(normalize_title($_->[0]), $_->[1], "strips: $_->[0]") for @strip;

# ---------------------------------------------------------------------------
# Normalization: things that must SURVIVE
#
# Each of these is destroyed by the naive version of the rule above.
# ---------------------------------------------------------------------------

my @keep = (
    # Leading parentheticals are part of the title.
    ['(Don\'t Fear) The Reaper'      => 'don t fear the reaper'],
    ['(I Can\'t Get No) Satisfaction'=> 'i can t get no satisfaction'],
    # Would normalize to the empty string if leading groups were stripped.
    ['(Antichrist Television Blues)' => 'antichrist television blues'],
    # Qualifier words appearing as real title words.
    ['Live and Let Die'              => 'live and let die'],
    ['Live Forever'                  => 'live forever'],
    ['Live Wire'                     => 'live wire'],
    ['Radio Ga Ga'                   => 'radio ga ga'],
    ['Radio Free Europe'             => 'radio free europe'],
    ['Video Killed the Radio Star'   => 'video killed the radio star'],
    ['Mono'                          => 'mono'],
    ['Acoustic #3'                   => 'acoustic 3'],
    # Trailing parenthetical that is NOT a qualifier.
    ['Hallelujah (I Love Her So)'    => 'hallelujah i love her so'],
);
is(normalize_title($_->[0]), $_->[1], "keeps: $_->[0]") for @keep;

# ---------------------------------------------------------------------------
# Regressions for bugs that actually shipped
# ---------------------------------------------------------------------------

subtest 'BUG 1: qr// interpolation cancelled /i' => sub {
    # Interpolating a compiled regex yields (?^:...), and the ^ resets flags,
    # so qualifiers only matched lowercase input. Mixed case must strip.
    is normalize_title('Song (2011 Remastered Version)'), 'song', 'mixed case';
    is normalize_title('Song (2011 REMASTERED VERSION)'), 'song', 'upper case';
    is normalize_title('Song (2011 remastered version)'), 'song', 'lower case';
};

subtest 'BUG 3: smart quotes' => sub {
    # The real library stores U+2019, not U+0027.
    is normalize_title("All Too Well (Taylor\x{2019}s version)"), 'all too well',
        'curly apostrophe in qualifier';
    is normalize_title("Taylor's Version test (Taylor's Version)"), 'taylor s version test',
        'straight apostrophe still works';
    is normalize_title("Don\x{2019}t Stop"), normalize_title("Don't Stop"),
        'curly and straight normalize identically';
};

subtest 'diacritics' => sub {
    is normalize_title('Corazón Espinado'), 'corazon espinado', 'accented';
    is normalize_title('Björk'),            'bjork',            'umlaut';
};

subtest 'ampersand and elision folding' => sub {
    is normalize_title('Rock and Roll'), normalize_title("Rock 'n' Roll"), "and / 'n'";
    is normalize_title('Salt & Pepper'), 'salt and pepper', 'ampersand';
};

# ---------------------------------------------------------------------------
# Similarity: the token-subset trap
#
# Token-set ratio returns a perfect score for pure subsets. Levenshtein over the
# whole string is length-sensitive and does not. These pairs are DIFFERENT SONGS.
# ---------------------------------------------------------------------------

subtest 'subset titles must not match' => sub {
    my @local = map { { id => $_->[0], title => $_->[1], norm => normalize_title($_->[1]),
                        stripped => 0, live => 0 } }
        ( [1, 'I Want You Back'], [2, 'Love Song for a Vampire'], [3, 'Sister Christian'] );

    for my $want ('I Want You', 'Love Song', 'Sister') {
        my ($status) = match_title($want, \@local);
        is $status, 'MISS', "\"$want\" does not swallow a longer title";
    }
};

subtest 'short titles allow no fuzz' => sub {
    my @local = map { { id => $_->[0], title => $_->[1], norm => normalize_title($_->[1]),
                        stripped => 0, live => 0 } }
        ( [1, 'Home Again'], [2, 'One More Time'], [3, 'Numb Encore'] );

    for my $want ('Home', 'One', 'Numb') {
        my ($status) = match_title($want, \@local);
        is $status, 'MISS', "\"$want\" is too short to fuzzy match";
    }
};

subtest 'exact match still works' => sub {
    my @local = ( { id => 1, title => 'Ants Marching', norm => normalize_title('Ants Marching'),
                    stripped => 0, live => 0 } );
    my ($status, $c) = match_title('Ants Marching', \@local);
    is $status, 'MATCH', 'status';
    is $c->[0]{id}, 1, 'right track';
};

# ---------------------------------------------------------------------------
# Version selection
# ---------------------------------------------------------------------------

sub cand {
    my (%a) = @_;
    return { id => $a{id}, title => $a{title}, album => $a{album}, album_id => $a{album_id} // $a{id},
             year => $a{year}, duration => $a{duration}, live => $a{live} // 0,
             stripped => $a{stripped} // 0, norm => normalize_title($a{title} // '') };
}

subtest 'BUG 4: clean title beats a stripped variant' => sub {
    # Both normalize to "juicy", same year, neither live nor a compilation.
    # Before the fix this fell through to lowest track id and picked the edit.
    my @c = (
        cand(id => 10, title => 'Juicy (Radio Edit)', album => 'Juicy',        year => 1994, stripped => 1),
        cand(id => 99, title => 'Juicy',              album => 'Ready to Die', year => 1994, stripped => 0),
    );
    is choose_version(\@c)->{album}, 'Ready to Die', 'picks the unqualified title';
};

subtest 'live handling is reference-dependent' => sub {
    my @c = (
        cand(id => 1, title => 'Show Me the Way', album => 'Frampton',            year => 1975, live => 0),
        cand(id => 2, title => 'Show Me the Way', album => 'Frampton Comes Alive', year => 1976, live => 1),
    );
    is choose_version(\@c, ref_live => 0)->{id}, 1, 'studio when reference is not live';
    is choose_version(\@c, ref_live => 1)->{id}, 2, 'live when reference IS live';
};

subtest 'duration outranks year' => sub {
    # The 1971-tagged candidate is a radio edit; duration should overrule the
    # year signal, which is the weakest one available.
    my @c = (
        cand(id => 1, title => 'Song', album => 'Reissue', year => 1971, duration => 180),
        cand(id => 2, title => 'Song', album => 'Original', year => 1987, duration => 537),
    );
    is choose_version(\@c, ref_duration => 540)->{id}, 2, 'duration window wins';
};

subtest 'junk years do not win' => sub {
    # Budget compilations tag year 0 or 1900, which would sort first on year.
    my @c = (
        cand(id => 1, title => 'Song', album => 'Budget Comp', year => 0),
        cand(id => 2, title => 'Song', album => 'Real Album',  year => 1979),
    );
    is choose_version(\@c)->{id}, 2, 'year 0 is ignored, not treated as earliest';
};

subtest 'deterministic on a true tie' => sub {
    my @c = (
        cand(id => 7, title => 'Song', album => 'A', year => 1980),
        cand(id => 3, title => 'Song', album => 'B', year => 1980),
    );
    is choose_version(\@c)->{id}, 3, 'lowest id, stable across runs';
    is choose_version([reverse @c])->{id}, 3, 'input order does not matter';
};

# ---------------------------------------------------------------------------
# Artist normalization
# ---------------------------------------------------------------------------

subtest 'artist normalization' => sub {
    is normalize_artist('The Notorious B.I.G.'), 'notorious b i g', 'punctuation and article';
    is normalize_artist('Mt. Joy'),              'mt joy',          'abbreviation';
    is normalize_artist('Bruce Springsteen & the E Street Band'),
       'bruce springsteen and the e street band', 'ampersand';
    isnt normalize_artist('The The'), '', 'article stripping does not empty a band name';
};

subtest 'live detection' => sub {
    ok  is_live_title('Free Bird - Live at the Fox'), 'dash form';
    ok  is_live_title('Song (Live)'),                 'paren form';
    ok  is_live_title('Song (Unplugged)'),            'unplugged in qualifier position';
    ok !is_live_title('Live and Let Die'),            'live as a real title word';
    ok !is_live_title('Live Forever'),                'live as a real title word, Oasis';
    ok !is_live_title('Live Wire'),                   'live as a real title word, AC/DC';
    ok  is_live_album('MTV Unplugged'),               'albums use the looser rule';
    ok  is_live_album('Live at Leeds'),               'album with leading live';
    ok !is_live_album('Ready to Die'),                'studio album';

    # KNOWN GAP, asserted so it cannot regress silently.
    # "Frampton Comes Alive!" and "One More From the Road" are live albums with
    # no live marker at all. Nothing textual can catch these. The consequence is
    # only a lost tie-break, never a lost track, so this is accepted rather than
    # fixed. If it ever matters, the fix is a duration check, not more regex.
    ok !is_live_album('Frampton Comes Alive!'),  'unmarked live album, known gap';
    ok !is_live_album('One More From the Road'), 'unmarked live album, known gap';
};

done_testing();
