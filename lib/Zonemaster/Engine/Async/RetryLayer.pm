package Zonemaster::Engine::Async::RetryLayer;
use v5.26;
use warnings;

use Carp  qw( croak );
use Errno qw( ETIMEDOUT );

sub new {
    my ( $class, %args ) = @_;

    my (    #
        $inner,
        $tries,
        $delay,
      )
      = delete @args{
        qw(
          inner
          tries
          delay
        )
      };
    if ( %args ) {
        croak 'unrecognized args: ' . join( ', ', sort keys %args );
    }

    defined $inner     or croak 'undefined inner';
    defined $tries     or croak 'undefined tries';
    $tries =~ /^\d+\z/ or croak 'tries must be non-negative integer';
    $delay //= 0;
    $delay >= 0 or croak 'delay must be non-negative';

    my $obj = {
        # The wrapped dispatcher interface implementation
        _inner => $inner,

        # Configuration: Number of tries before giving up
        _tries => $tries,

        # Configuration: Number of seconds to wait before trying again
        _delay => $delay,

        # The set of outstanding exchanges
        _exchanges => {},

        # The set of retry counters for all outstanding retried exchanges
        _retry_timers => {},
    };

    return bless $obj, $class;
} ## end sub new

sub add_timeout {
    my ( $self, $timeout ) = @_;

    return $self->{_inner}->add_timeout( $timeout );
}

sub add_request {
    my ( $self, $query ) = @_;

    my $qid = $self->{_inner}->add_request( $query );
    $self->{_exchanges}{$qid} = [ $self->{_tries}, $query ];

    return $qid;
}

sub step {
    my ( $self ) = @_;

    my @events;
    my @pairs = $self->{_inner}->step();

    while ( @pairs ) {
        my ( $qid, $event ) = splice @pairs, 0, 2;

        if ( my $exchange = delete $self->{_exchanges}{$qid} ) {
            my ( $remaining, $query ) = $exchange->@*;

            if ( !ref $packet && $packet == &ETIMEDOUT && $remaining > 0 ) {
                if ( $self->{_delay} > 0 ) {
                    my $qid = $self->{_inner}->add_timeout( $self->{_delay} );
                    $self->{_retry_timers}{$qid} = [ $remaining - 1, $query ];
                }
                else {
                    my $qid = $self->{_inner}->add_request( $query );
                    $self->{_exchanges}{$qid} = [ $remaining - 1, $query ];
                }
                next;    # swallow this timeout
            }

            push @events, $qid, $event;    # success or final timeout; pass through
        }
        elsif ( my $timer = delete $self->{_retry_timers}{$qid} ) {
            my ( $remaining, $query ) = $timer->@*;

            my $qid = $self->{_inner}->add_request( $query );
            $self->{_exchanges}{$qid} = [ $remaining, $query ];
            next;                          # swallow this timer event
        }
        else {
            push @events, $qid, $event;    # not ours; pass through
        }
    } ## end while ( @pairs )

    return @events;
} ## end sub step

1;
