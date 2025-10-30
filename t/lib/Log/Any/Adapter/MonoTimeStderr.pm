package Log::Any::Adapter::MonoTimeStderr;
use strict;
use warnings;
use parent 'Log::Any::Adapter::Base';

use Carp                    qw(croak);
use Log::Any::Adapter::Util qw( numeric_level detection_methods );
use Time::HiRes             qw(clock_gettime CLOCK_MONOTONIC);
use Test2::API              qw( context_do );

# Called by Base->new; do not override new()
sub init {
    my ( $self ) = @_;
    # config
    $self->{log_level} //= 'trace';    # minimum level to emit
    $self->{_min} = numeric_level( $self->{log_level} );
}

sub structured {
    my ( $self, $level_name, $category, @args ) = @_;

    my $lvl = numeric_level( $level_name );
    return if $lvl > $self->{_min};    # level filter

    # elapsed monotonic time with microseconds
    my $t   = clock_gettime( CLOCK_MONOTONIC );
    my $sec = int( $t );
    my $us  = int( ( $t - $sec ) * 1_000_000 + 0.5 );
    if ( $us >= 1_000_000 ) { $sec++; $us -= 1_000_000 }    # carry after rounding

    # stringify args; pretty-print refs on one line
    my @parts = map { ref $_ ? dump_one_line( $_ ) : $_ } @args;
    my $msg   = join( ' ', @parts );
    $msg =~ s/\n\z//;

    context_do {
        my $ctx = shift;
        $ctx->note( sprintf( "%d.%06d %s\n", $sec, $us, $msg ) );
    }
} ## end sub structured

# Required detection methods: is_trace, is_debug, ...
BEGIN {
    no strict 'refs';
    for my $meth ( detection_methods() ) {
        my ( $lname ) = $meth =~ /^is_(.+)$/;
        my $num = numeric_level( $lname );
        *{$meth} = sub {
            my ( $self ) = @_;
            return $num <= ( $self->{_min} // numeric_level( 'trace' ) );
        };
    }
}

1;
