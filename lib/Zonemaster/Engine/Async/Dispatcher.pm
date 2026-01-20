package Zonemaster::Engine::Async::Dispatcher;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Errno qw( EINTR ETIMEDOUT );
use IO::Select;
use IO::Socket::INET;
use List::Util qw( max min pairmap );
use Log::Any   qw( $log );
use Role::Tiny::With;
use Time::HiRes qw( clock_gettime CLOCK_MONOTONIC );

use Zonemaster::Engine::Async qw( errno_names );
use Zonemaster::Engine::Async::UDPTransport;
use Zonemaster::Engine::Async::Error qw( $TRANSIENT_KIND );

with 'Zonemaster::Engine::Async::SessionRole';

sub new {
    my ( $class, %args ) = @_;

    my (    #
        $exchange_timeout,
        $mono_time,
        $qid_allocator,
        $select_fn,
        $transport_factory,
      )
      = delete @args{
        qw(
          exchange_timeout
          mono_time
          qid_allocator
          select_fn
          transport_factory
        )
      };
    if ( %args ) {
        croak 'unrecognized args: ' . join( ', ', sort keys %args );
    }

    if ( !defined $exchange_timeout ) {
        croak 'undefined exchange timeout';
    }

    $mono_time         //= \&_default_mono_time;
    $qid_allocator     //= \&_default_qid_allocator;
    $select_fn         //= \&_default_select_fn;
    $transport_factory //= \&_default_transport_factory;

    my $obj = {
        _deadlines         => {},
        _udp               => undef,
        _exchange_timeout  => $exchange_timeout,
        _mono_time         => $mono_time,
        _qid_allocator     => $qid_allocator,
        _select_fn         => $select_fn,
        _transport_factory => $transport_factory,
    };

    return bless $obj, $class;
} ## end sub new

sub add_timeout {
    my ( $self, $timeout ) = @_;

    if ( keys $self->{_deadlines}->%* >= 65536 ) {
        croak 'qid exhaustion';
    }

    my $qid = $self->{_qid_allocator}( $self->{_deadlines} );

    my $deadline = $self->_now_mono + $timeout;
    $log->tracef( 'add_timeout: %f', $deadline );

    $self->{_deadlines}{$qid} = $deadline;

    return $qid;
}

sub add_request {
    my ( $self, $query ) = @_;

    if ( !defined $self->{_udp} ) {
        $self->{_udp} = $self->{_transport_factory}();
    }

    my $qid = $self->add_timeout( $self->{_exchange_timeout} );

    $self->{_udp}->enqueue( $qid, $query );

    return $qid;
}

=head2 step()

Send pending requests, return received responses, and/or transpired timeouts.

Blocks until any progress can be made, or returns immediately if there is nothing to be done.

Returns a flattened list of (query id, response/timeout)-pairs.
A response is represented as a Zonemaster::Engine::Packet, and a timeout as a
Zonemaster::Engine::Async::Error.

=cut

sub step {
    my ( $self ) = @_;

    $log->tracef( 'step: enter (%d deadlines)', scalar keys $self->{_deadlines}->%* );

    if ( !$self->{_deadlines}->%* ) {
        $log->trace( 'step: nothing to do' );
        return;
    }

    my $want_read = IO::Select->new();
    if ( $self->{_udp}->want_read ) {
        $log->trace( 'step: want read' );
        $want_read->add( $self->{_udp}->io_handle );
    }

    my $want_write = IO::Select->new();
    if ( $self->{_udp}->want_write ) {
        $log->trace( 'step: want write' );
        $want_write->add( $self->{_udp}->io_handle );
    }

    my $earliest_deadline = min values $self->{_deadlines}->%*;

    my @results;
    do {
        my $now_mono = $self->_now_mono;
        my $timeout  = max 0, $earliest_deadline - $now_mono;
        $log->tracef( 'step: select %d %d 0 %fs', scalar $want_read->handles, scalar $want_write->handles, $timeout );
        local $ERRNO = 0;
        if ( my ( $readable, $writable, undef ) = $self->{_select_fn}( $want_read, $want_write, $timeout ) ) {
            if ( $writable->@* ) {
                my ( $socket_errno, @new_results ) = $self->{_udp}->handle_writable;
                push @results, @new_results;
                if ( $socket_errno == ENOBUFS || $socket_errno == ENOMEM ) {
                    # TODO enable backpressure:
                    #  * set a deadline before which no file handles are to be
                    #    included in the call to select().
                    #  * immediately time out tasks that time out before the deadline.
                    #  * handle readable also, but then break out of the loop.
                }
            }
            if ( $readable->@* ) {
                my @new_results = $self->{_udp}->handle_readable;
                for my $packet ( @new_results ) {
                    my $qid = $packet->id();
                    delete $self->{_deadlines}{$qid};
                    push @results, $qid, $packet;
                }
            }
        } ## end if ( my ( $readable, $writable...))
        elsif ( $!{EINTR} ) {
            $log->trace( 'step: EINTR' );
            redo;
        }
        elsif ( $ERRNO ) {
            croak
              sprintf( "select failed: %s (%d%s)", $ERRNO, $ERRNO,
                join( '', map { "/$_" } errno_names( $ERRNO )->@* ) );
        }
    } while ( 0 );

    my $now_mono = $self->_now_mono;
    my @expired  = pairmap { $b <= $now_mono ? ( $a ) : () } $self->{_deadlines}->%*;

    $log->tracef( 'step: %d results, %d expired', @results / 2, scalar @expired );

    for my $qid ( @expired ) {
        delete $self->{_deadlines}{$qid};
        $self->{_udp}->cancel( $qid );
        push @results, ( $qid, Zonemaster::Engine::Async::Error->from_timeout( $TRANSIENT_KIND, 'request' ) );
    }

    return @results;
} ## end sub step

sub _now_mono {
    my ( $self ) = @_;

    return $self->{_mono_time}();
}

sub _default_mono_time {
    return clock_gettime( CLOCK_MONOTONIC );
}

sub _default_qid_allocator {
    my ( $deadlines ) = @_;

    # Linearly walk the range of qids with a random step size from a random starting point
    # until an available qid is found. An uninterrupted walk is guaranteed to visit all
    # other QIDs before returning to the starting point because no odd numbers have any
    # common divisor with the range size.
    my $qid  = int( rand( 0x10000 ) );
    my $step = int( rand( 0x10000 ) ) | 0x0001;
    while ( exists $deadlines->{$qid} ) {
        $qid = ( $qid + $step ) & 0xffff;
    }

    return $qid;
}

sub _default_select_fn {
    my ( $r, $w, $t ) = @_;

    return IO::Select->select( $r, $w, undef, $t );
}

sub _default_transport_factory {
    return Zonemaster::Engine::Async::UDPTransport->new();
}

1;
