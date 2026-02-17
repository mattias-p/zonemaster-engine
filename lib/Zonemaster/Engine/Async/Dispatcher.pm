package Zonemaster::Engine::Async::Dispatcher;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Errno qw( EAGAIN EINTR ENOBUFS ENOMEM EWOULDBLOCK );
use IO::Select;
use IO::Socket::INET;
use List::Util qw( max min pairmap );
use Log::Any   qw( $log );
use Role::Tiny::With;
use Scalar::Util qw( refaddr );
use Time::HiRes  qw( clock_gettime CLOCK_MONOTONIC );

use Zonemaster::Engine::Async qw( errno_names );
use Zonemaster::Engine::Async::DispatcherResult;
use Zonemaster::Engine::Async::UDPTransport;

with 'Zonemaster::Engine::Async::SessionRole';

=pod
    Ok value:packet scope:task
    Err origin:ldns scope:task
    Err origin:os   scope:socket

    handle_writable
      socket:
        OsError  EINTR/EAGAIN/EWOULDBLOCK/ENOBUFS/ENOMEM
            no-progress         - ignore
            resource-exhaustion - destination/write
      task:
        OsError !EINTR/EAGAIN/EWOULDBLOCK/ENOBUFS/ENOMEM/EBADF/ENOTSOCK/EFAULT/EDESTADDRREQ/EISCONN
            fail-task           - fail-task

    handle_readable
      socket:
        LdnsError MEM_ERR
            resource-exhaustion - destination/read
        OsError !EBADF/ENOTSOCK/EINVAL/EFAULT
            no-progress         - ignore
            resource-exhaustion - destination/read
            fail-destination    - destination/read
            fail-socket         - destination/read

    set_dest_suppression(dest, (read|write)*) -> ()
    drain_dest(dest)                          -> [query]
    drop_dest(dest)                           -> [query]
=cut

sub new {
    my ( $class, %args ) = @_;

    my (    #
        $exchange_timeout,
        $mono_time,
        $qid_allocator,
        $select_fn,
        $transport_factory,
        $peer_port,
      )
      = delete @args{
        qw(
          exchange_timeout
          mono_time
          qid_allocator
          select_fn
          transport_factory
          peer_port
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
    $transport_factory //= sub {
        my ( $peer_ip ) = @_;
        _default_transport_factory( $peer_port, $peer_ip );
    };

    my $obj = {
        _deadlines         => {},
        _udp               => {},
        _transports        => {},
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

    my $peer_ip = $query->server;
    if ( !exists $self->{_udp}{$peer_ip} ) {
        my $transport = $self->{_transport_factory}( $peer_ip );
        my $refaddr   = refaddr( $transport->io_handle );
        $self->{_udp}{$peer_ip}        = $refaddr;
        $self->{_transports}{$refaddr} = $transport;
    }

    my $qid = $self->add_timeout( $self->{_exchange_timeout} );

    my $refaddr   = $self->{_udp}{$peer_ip};
    my $transport = $self->{_transports}{$refaddr};

    $transport->enqueue( $qid, $query );

    return $qid;
} ## end sub add_request

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

    my $want_read  = IO::Select->new();
    my $want_write = IO::Select->new();
    for my $transport ( values $self->{_transports}->%* ) {
        if ( $transport->want_read ) {
            $log->trace( 'step: want read' );
            $want_read->add( $transport->io_handle );
        }
        if ( $transport->want_write ) {
            $log->trace( 'step: want write' );
            $want_write->add( $transport->io_handle );
        }
    }

    my $earliest_deadline = min values $self->{_deadlines}->%*;

    my @results;
    do {
        my $now_mono = $self->_now_mono;
        my $timeout  = max 0, $earliest_deadline - $now_mono;

        $log->tracef( 'step: select %d %d 0 %fs', scalar $want_read->handles, scalar $want_write->handles, $timeout );
        local $ERRNO = 0;
        if ( my ( $readable, $writable, undef ) = $self->{_select_fn}( $want_read, $want_write, $timeout ) ) {
            for my $handle ( $writable->@* ) {
                my $refaddr   = refaddr( $handle );
                my $transport = $self->{_transports}{$refaddr};

                my ( $err, @new_results ) = $transport->handle_writable;
                push @results, @new_results;

                if ( defined $err ) {
                    if ( $err->isa( 'Zonemaster::Engine::Async::OsError' )
                        && ( $err->errno == ENOBUFS || $err->errno == ENOMEM ) )
                    {
                        push @results,
                          Zonemaster::Engine::Async::DispatcherResult->write_error(
                            proto => $transport->proto,
                            addr  => $transport->peeraddr,
                            error => $err,
                          );
                    }
                    elsif ( $err->isa( 'Zonemaster::Engine::Async::OsError' )
                        && ( $err->errno != EINTR && $err->errno != EAGAIN && $err->errno != EWOULDBLOCK ) )
                    {
                        $log->tracef( 'handle_writable: %s', $err );
                    }
                }
            } ## end for my $handle ( $writable...)

            for my $handle ( $readable->@* ) {
                my $refaddr   = refaddr( $handle );
                my $transport = $self->{_transports}{$refaddr};

                my ( $err, @new_results ) = $transport->handle_readable;

                for my $message ( @new_results ) {
                    my $qid = $message->id();
                    delete $self->{_deadlines}{$qid};
                    push @results,
                      Zonemaster::Engine::Async::DispatcherResult->task_ok(
                        task_id => $qid,
                        message => $message,
                      );
                }

                if ( defined $err ) {
                    if (
                        (
                            $err->isa( 'Zonemaster::Engine::Async::OsError' )
                            && ( $err->errno == ENOBUFS || $err->errno == ENOMEM )
                        )
                        || $err->isa( 'Zonemaster::Engine::Async::LdnsError' )
                      )
                    {
                        push @results,
                          Zonemaster::Engine::Async::DispatcherResult->read_error(
                            proto => $transport->proto,
                            addr  => $transport->peeraddr,
                            error => $err,
                          );
                    }
                    elsif ( $err->isa( 'Zonemaster::Engine::Async::OsError' )
                        && ( $err->errno != EINTR && $err->errno != EAGAIN && $err->errno != EWOULDBLOCK ) )
                    {
                        $log->tracef( 'handle_readable: %s', $err );
                    }
                } ## end if ( defined $err )
            } ## end for my $handle ( $readable...)
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

    $log->tracef( 'step: %d results, %d expired', scalar @results, scalar @expired );

    for my $qid ( @expired ) {
        delete $self->{_deadlines}{$qid};

        push @results, Zonemaster::Engine::Async::DispatcherResult->task_timeout( task_id => $qid );

        # We're tracking which deadline are associated with which transports, so just try
        # to cancel the exchange in all the transports. Since the QID is unique across all
        # transports, there's no risk for colleteral damage.
        for my $transport ( values $self->{_transports}->%* ) {
            $transport->cancel( $qid );
        }
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
    my ( $peer_port, $peer_ip ) = @_;

    my $socket = IO::Socket::INET->new(
        Proto    => 'udp',
        PeerHost => $peer_ip,
        PeerPort => $peer_port,
        Blocking => 0,
    );

    if ( $socket ) {
        return Zonemaster::Engine::Async::UDPTransport->new( socket => $socket );
    }
    else {
        return;
    }
}

1;
