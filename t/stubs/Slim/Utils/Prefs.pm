package Slim::Utils::Prefs;
use Exporter 'import';
our @EXPORT=qw(preferences);
sub preferences { bless {}, 'Slim::Utils::Prefs::Obj' }
package Slim::Utils::Prefs::Obj;
sub get {undef} sub set {1} sub client {shift}
1;
