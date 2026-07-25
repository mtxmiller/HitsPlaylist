package Slim::Web::Settings;

# Compile-only stub. The real one renders the Template Toolkit page and persists
# prefs. Never assert behaviour against this.

sub new     { bless {}, shift }
sub handler { 1 }
sub name    { '' }
sub page    { '' }
sub prefs   { () }

1;
