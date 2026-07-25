package Slim::Utils::Log;
use Exporter 'import';
our @EXPORT=qw(logger);
sub addLogCategory { bless {}, 'Slim::Utils::Log::Obj' }
sub logger { bless {}, 'Slim::Utils::Log::Obj' }
package Slim::Utils::Log::Obj;
sub error {1} sub debug {1} sub info {1} sub warn {1}
sub is_debug {0} sub is_info {0}
1;
