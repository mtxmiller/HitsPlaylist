package Plugins::HitsPlaylist::Settings;

# Settings > Plugins > Hits Playlist
#
# Every value here was a constant I picked. Three of them turned out to be wrong
# for a real library within an hour of use, which is decent evidence the rest
# should not be my call either.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.hitsplaylist');
my $prefs = preferences('plugin.hitsplaylist');

sub name        { 'PLUGIN_HITSPLAYLIST_NAME' }
sub page        { 'plugins/HitsPlaylist/settings.html' }
sub prefs       { return ($prefs, qw(playlistLength similarArtists preferCompilation apikey)) }

sub handler {
    my ($class, $client, $paramRef) = @_;

    if ( $paramRef->{saveSettings} ) {
        # An API key pasted from Last.fm is 32 hex characters. People paste it
        # with whitespace, or paste the shared secret by mistake, or paste the
        # UUID-with-dashes form. Normalise what we can and reject the rest
        # rather than silently making every lookup fail with a 403.
        my $key = $paramRef->{pref_apikey} // '';
        $key =~ s/[^0-9a-fA-F]//g;

        if ( length($key) && length($key) != 32 ) {
            $paramRef->{warning} = Slim::Utils::Strings::string('PLUGIN_HITSPLAYLIST_BAD_KEY');
            $paramRef->{pref_apikey} = '';
        }
        else {
            $paramRef->{pref_apikey} = $key;
        }
    }

    return $class->SUPER::handler($client, $paramRef);
}

1;
