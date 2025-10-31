package Zonemaster::Engine::Async::Dispatcher;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Errno qw( EINTR ETIMEDOUT );
use IO::Select;
use List::Util qw( max min pairmap );
use Log::Any   qw( $log );

use Zonemaster::Engine::Async qw( errno_names );

sub new {
    my ( $class, %args ) = @_;

    my (    #
        $exchange_timeout,
        $mono_time,
        $transport_factory,
      )
      = delete @args{
        qw(
          exchange_timeout
          mono_time
          transport_factory
        )
      };
    if ( %args ) {
        croak 'unrecognized args: ' . join( ', ', sort keys %args );
    }

    if ( !defined $exchange_timeout ) {
        croak 'undefined exchange timeout';
    }
    if ( !defined $mono_time ) {
        croak 'undefined mono time';
    }
    if ( !defined $transport_factory ) {
        croak 'undefined transport factory';
    }

    my $obj = {
        _deadlines         => {},
        _udp               => undef,
        _exchange_timeout  => $exchange_timeout,
        _mono_time         => $mono_time,
        _transport_factory => $transport_factory,
    };

    return bless $obj, $class;
} ## end sub new

sub add_timeout {
    my ( $self, $timeout ) = @_;

    if ( keys $self->{_deadlines}->%* >= 65536 ) {
        croak 'qid exhaustion';
    }

    # Linearly walk the range of qids with a random step size from a random starting point
    # until an available qid is found. An uninterrupted walk is guaranteed to visit all
    # other QIDs before returning to the starting point because no odd numbers have any
    # common divisor with the range size.
    my $qid  = int( rand( 0x10000 ) );
    my $step = int( rand( 0x10000 ) ) | 0x0001;
    while ( exists $self->{_deadlines}{$qid} ) {
        $qid = ( $qid + $step ) & 0xffff;
    }

    my $deadline = $self->_now_mono + $timeout;
    $log->tracef( 'add_timeout: %f', $deadline );

    $self->{_deadlines}{$qid} = $deadline;

    return $qid;
} ## end sub add_timeout

sub add_request {
    my ( $self, $query ) = @_;

    if ( !defined $self->{_udp} ) {
        $self->{_udp} = $self->{_transport_factory}->();
    }

    my $qid = $self->add_timeout( $self->{_exchange_timeout} );

    $self->{_udp}->enqueue( $qid, $query );

    return $qid;
}

sub poll_responses {
    my ( $self ) = @_;

    $log->tracef( 'poll_responses: enter (%d deadlines)', scalar keys $self->{_deadlines}->%* );

    if ( !$self->{_deadlines}->%* ) {
        $log->trace( 'poll_responses: nothing to do' );
        return;
    }

    my $want_read = IO::Select->new();
    if ( $self->{_udp}->want_read ) {
        $log->trace( 'poll_responses: want read' );
        $want_read->add( $self->{_udp}->socket );
    }

    my $want_write = IO::Select->new();
    if ( $self->{_udp}->want_write ) {
        $log->trace( 'poll_responses: want write' );
        $want_write->add( $self->{_udp}->socket );
    }

    my $earliest_deadline = min values $self->{_deadlines}->%*;

    my @results;
    do {
        my $now_mono = $self->_now_mono;
        my $timeout  = max 0, $earliest_deadline - $now_mono;
        $log->tracef(
            'poll_responses: select %d %d 0 %fs',
            scalar $want_read->handles,
            scalar $want_write->handles, $timeout
        );
        local $ERRNO = 0;
        if ( my ( $readable, $writable, undef ) = IO::Select->select( $want_read, $want_write, undef, $timeout ) ) {
            if ( $writable->@* ) {
                $self->{_udp}->on_writable;
            }
            if ( $readable->@* ) {
                my @new_results = $self->{_udp}->on_readable;
                for my $packet ( @new_results ) {
                    my $qid = $packet->id();
                    delete $self->{_deadlines}{$qid};
                    push @results, $qid, $packet;
                }
            }
        }
        elsif ( $!{EINTR} ) {
            $log->trace( 'poll_response: EINTR' );
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

    $log->tracef( 'poll_response: %d results, %d expired', @results / 2, scalar @expired );

    for my $qid ( @expired ) {
        delete $self->{_deadlines}{$qid};
        $self->{_udp}->drop( $qid );
        push @results, ( $qid, &ETIMEDOUT );
    }

    return @results;
} ## end sub poll_responses

sub _now_mono {
    my ( $self ) = @_;

    return $self->{_mono_time}->();
}

1;
