#!/usr/bin/env perl

# Compile-check every plugin module without a running LMS.
#
# The plugin cannot be unit tested the way the matcher can: it talks to
# Slim::Schema, Slim::Menu::ArtistInfo and the async HTTP stack, none of which
# exist outside a server. What this DOES catch is the failure that actually
# happens in practice: a typo, a bad import, or a missing sub that turns into
# "plugin failed to load" with a stack trace in server.log and no menu item.
#
# t/stubs/ holds do-nothing versions of the Slim:: modules. They exist to make
# the compiler happy, not to simulate LMS. Never assert behaviour against them.

use strict;
use warnings;

use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $root  = abs_path(dirname(__FILE__) . '/..');
my $stubs = "$root/t/stubs";

my @modules = glob("$root/Plugins/HitsPlaylist/*.pm");

plan skip_all => 'no plugin modules found' unless @modules;

for my $module (@modules) {
    my $name = $module;
    $name =~ s{^\Q$root\E/}{};

    my $out = `cd '$root' && perl -I'$stubs' -I'$root' -MLMSStubs -c '$module' 2>&1`;
    my $ok  = ($? == 0 && $out =~ /syntax OK/);

    ok($ok, "compiles: $name") or diag($out);
}

# The generated copy must not drift from the tested source. If someone edits the
# matcher and forgets tools/sync-matcher.sh, the plugin ships different code than
# t/matcher.t proved correct, and nothing else would notice.
subtest 'plugin matcher is in sync with the tested source' => sub {
    my $src = "$root/lib/HitsPlaylist/Matcher.pm";
    my $dst = "$root/Plugins/HitsPlaylist/Matcher.pm";

    plan skip_all => 'no generated copy yet' unless -f $dst;

    my $strip = sub {
        my ($path) = @_;
        open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
        local $/;
        my $body = <$fh>;
        close $fh;
        $body =~ s/^package \S+;\n//m;
        $body =~ s/^# GENERATED FILE.*?\n(?:#.*\n)*\n//m;
        return $body;
    };

    is $strip->($dst), $strip->($src),
        'Plugins/HitsPlaylist/Matcher.pm matches lib/HitsPlaylist/Matcher.pm (run tools/sync-matcher.sh)';
};

done_testing();
