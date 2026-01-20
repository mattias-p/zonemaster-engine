package My::Test::Select;
use v5.26;
use warnings;

use English;
use Errno    qw( EWOULDBLOCK );
use Exporter qw( import );
use IO::Select;
use My::Test::Clock qw( advance_time );

our @EXPORT_OK = qw(
  select
);

use Data::Dumper;

sub select {
    my ( $r, $w, $timeout_ms ) = @_;

    my @result;
    my $errno = do {
        local $ERRNO = 0;
        @result = IO::Select->select( $r, $w, undef, 0 );
        $ERRNO;
    };

    if ( @result ) {
        return @result;
    }

    if ( $errno == 0 ) {
        local $ERRNO;
        advance_time( $timeout_ms );
    }
    else {
        $ERRNO = $errno;
    }

    return;
} ## end sub select

1;
