package Zonemaster::Engine::Async::TCPTransport;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Errno    qw( EINTR EAGAIN EWOULDBLOCK ENOBUFS EBADMSG );
use Log::Any qw( $log );
use IO::Socket;
use Role::Tiny::With          qw( with );
use Socket                    qw( IPPROTO_TCP TCP_NODELAY SOL_SOCKET SO_NOSIGPIPE MSG_NOSIGNAL );
use Zonemaster::Engine::Async qw( pack_sockaddr unpack_sockaddr );

with 'Zonemaster::Engine::Async::TransportRole';

use constant MAX_RECV_HINT   => 65535;
use constant DNS_HEADER_SIZE => 12;

sub new {
    my ( $class, %args ) = @_;
    my (    #
        $peeraddr,
        $peerport,
        $socket_class,
      )
      = delete @args{
        qw(
          peerport
          peeraddr
          socket_class
        )
      };

    # an exchange is a hash with keys: {seq, qid, buffer, offset, qname, qtype, qclass}

    my $obj = {
        _socket_class => $socket_class,
        _peeraddr     => $peeraddr,
        _peerport     => $peerport,
        _seq          => 0,
        _rbuf         => '',
        _connecting   => undef,
        _socket       => undef,
        _pending      => [],              # an array of exchanges; see above
        _active       => {},              # hash from QID to exchange; see above
    };

    return bless $obj, $class;
} ## end sub new

sub reset {
    my ( $self ) = @_;

    # Move active exchanges back into pending queue, preserving insertion order
    my @qids = sort {    #
        $self->{_active}{$a}{seq} <=> $self->{_active}{$b}{seq}
    } keys $self->{_active};
    splice $self->{_pending}, 0, 0, map { $_->{offset} = 0; $_ } delete $self->{_active}->@{@qids};

    return;
}

sub _flush_with_error {
    my ( $self, $err ) = @_;

    $self->reset;

    return map { $_->{qid} => $err } splice( $self->{_pending} );
}

sub disconnect {
    my ( $self ) = @_;

    $self->{_socket} = undef;

    return;
}

sub io_handle {
    my ( $self ) = @_;

    return $self->{_socket} // $self->{_connecting};
}

sub enqueue {
    my ( $self, $qid, $query ) = @_;

    my $dst_addr        = pack_sockaddr( $query->server(), $self->{_peerport} );
    my $packet          = $query->mk_packet( $qid );
    my ( $question_rr ) = $packet->question();

    push $self->{_pending}->@*,
      {
        seq    => $self->{_seq}++,
        wbuf   => $packet->data,
        offset => 0,
        qid    => $qid,
        qname  => $question_rr->name(),
        qtype  => $question_rr->type(),
        qclass => $question_rr->class(),
      };

    return;
} ## end sub enqueue

sub cancel {
    my ( $self, $qid ) = @_;

    if ( !delete $self->{_active}{$qid} ) {
        $self->{_pending}->@* = grep { $_->{qid} != $qid } $self->{_pending}->@*;
    }

    return;
}

sub want_write {
    my ( $self ) = @_;

    my $want_write = $self->{_pending}->@* > 0;

    if ( $want_write && !$self->{_socket} && !$self->{_connecting} ) {
        my $err = $self->_connect_start();
        if ( $err ) {
            return 0, $self->_flush_with_error( $err );
        }
    }

    return $want_write;
}

sub want_read {
    my ( $self ) = @_;

    return $self->{_active}->%* > 0;
}

sub handle_writable {
    my ( $self ) = @_;

    if ( $self->{_connecting} ) {
        my @events = $self->_connect_finish();
        if ( @events ) {
            return @events;
        }
    }

    my @events;
  QUEUE:
    while ( $self->{_pending}->@* ) {
        my $exchange = shift $self->{_pending}->@*;

        local $ERRNO = 0;
        for ( ; ; ) {
            my $length = length( $exchange->{wbuf} ) - $exchange->{offset};
            my $sent   = $self->{_socket->syswrite( $exchange->{wbuf}, $length, $exchange->{offset} );

            if ( defined $sent ) {
                $exchange->{offset} += $sent;

                last QUEUE if $sent == 0;
                redo       if $sent < $length;

                $self->{_active}{$qid} = $exchange;

                next QUEUE;
            }

            redo       if $!{EINTR};
            last QUEUE if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOBUFS};

            if ( $!{EPIPE} ) {
                $self->_disconnect();

                my $err = Zonemaster::Engine::Async::SocketErrnoError->new( $ERRNO );
                push @events, ( $exchange->{qid}, $err );
                push @events, $self->_flush_with_error( $err );

                last QUEUE;
            }

            croak sprintf( 'syswrite: %s (%d)', $ERRNO, $ERRNO );
        } ## end for ( ; ; )
    } ## end QUEUE: while ( $self->{_pending}...)

    return @events;
} ## end sub handle_writable

sub handle_readable {
    my ( $self ) = @_;

    my @events;
  ACTIVE:
    while ( $self->{_active}->%* ) {
        local $ERRNO = 0;

        if ( length $self->{_rbuf} < 2 ) {
            my $offset = length $self->{_rbuf};
            my $bytes;
            for ( ; ; ) {
                $bytes = $self->{_socket}->sysread( $self->{_rbuf}, 2 - $offset, $offset );
                last if defined $bytes;
                last if $!{EWOULDBLOCK} || $!{EAGAIN};
                redo if $!{EINTR};

                croak sprintf( 'sysread: %s (%d)', $ERRNO, $ERRNO );
            }

            if ( $bytes == 0 ) {
                $self->disconnect();

                my $err = Zonemaster::Engine::Async::SocketClosedError->new();
                push @events, $self->_flush_with_error( $err );
                last;
            }
        } ## end if ( length $self->{_rbuf...})

        if ( length $self->{_rbuf} >= 2 ) {
            my $length = unpack( 'n', $self->{_rbuf} );

            while ( length $self->{_rbuf} < 2 + $length ) {
                my $offset    = length( $self->{_rbuf} );
                my $remaining = 2 + $length - $offset;

                my $bytes;
                for ( ; ; ) {
                    $bytes = $self->{_socket}->sysread( $self->{_rbuf}, $remaining, $offset );
                    last        if defined $bytes;
                    redo        if $!{EINTR};
                    last ACTIVE if $!{EWOULDBLOCK} || $!{EAGAIN};

                    croak sprintf( 'sysread: %s (%d)', $ERRNO, $ERRNO );
                }

                if ( $bytes == 0 ) {
                    $self->disconnect();

                    my $err = Zonemaster::Engine::Async::SocketClosedError->new();
                    push @events, $self->_flush_with_error( $err );
                    last ACTIVE;
                }
            } ## end while ( length $self->{_rbuf...})

            if ( $length < DNS_HEADER_SIZE ) {
                $log->tracef( 'handle_readable: incomplete header (%d bytes); retry', $length );
                redo ACTIVE;
            }

            my $qid      = unpack( 'n', $self->{_rbuf} );
            my $exchange = $self->{_active}{$qid};
            if ( !$exchange ) {
                $log->trace( 'handle_readable: no matching QID; retry' );
                redo;
            }

            my $packet = Zonemaster::LDNS::Packet->new_from_wireformat2( substr( $self->{_rbuf}, 2 ) );
            if ( !defined $packet ) {
                if ( $!{EBADMSG} ) {
                    $log->trace( 'handle_readable: parse->EBADMSG; retry' );
                    redo;
                }
                croak sprintf( "parse: %s (%d)", $ERRNO, $ERRNO );
            }

            if ( !$packet->qr() ) {
                $log->trace( 'handle_readable: QR=0; retry' );
                redo;
            }

            my @question_rrs = $packet->question();
            if ( @question_rrs != 1 ) {
                $log->tracef( 'handle_readable: QDCOUNT=%d; retry', scalar @question_rrs );
                redo;
            }

            if ( $question_rrs[0]->type() ne $exchange->{qtype} ) {
                $log->trace( 'handle_readable: QTYPE mismatch; retry' );
                redo;
            }

            if ( $question_rrs[0]->class() ne $exchange->{qclass} ) {
                $log->trace( 'handle_readable: QCLASS mismatch; retry' );
                redo;
            }

            if ( lc( $question_rrs[0]->name() ) ne $exchange->{qname} ) {
                $log->trace( 'handle_readable: QNAME mismatch; retry' );
                redo;
            }
        } ## end if ( length $self->{_rbuf...})

        push @events, ( $exchange->{qid}, $packet );

        delete $self->{_active}{$qid};
    } ## end ACTIVE: while ( $self->{_active}->...)

    return @events;
} ## end sub handle_readable

sub send_queue_len {
    my ( $self ) = @_;

    return scalar( $self->{_pending}->@* );
}

sub inflight_count {
    my ( $self ) = @_;

    return scalar keys $self->{_active}->%*;
}

sub _connect_start {
    my ( $self ) = @_;
    my $sock;

    local $ERRNO = 0;
    do {
        $sock = $self->{_socket_class}->new(
            PeerAddr => $self->{_host},
            PeerPort => $self->{_port},
            Proto    => 'tcp',
            Blocking => 0,
        );
    } while ( $!{EINTR} );

    if ( !$sock ) {
        my $err =
            $!{EADDRNOTAVAIL}                   ? Zonemaster::Engine::Async::TransientError->new( $ERRNO )
          : $!{ECONNREFUSED} || $!{ENETUNREACH} ? Zonemaster::Engine::Async::AddressError->new( $ERRNO )
          :                                       undef;

        if ( $err ) {
            return $err;
        }

        croak sprintf( "connect: %s (%d)", $ERRNO, $ERRNO );
    }

    $sock->setsockopt( IPPROTO_TCP, TCP_NODELAY, pack( "i", 1 ) )
      or croak sprintf( "setsockopt TCP_NODELAY: %s (%d)", $ERRNO, $ERRNO );
    $sock->setsockopt( SOL_SOCKET, SO_KEEPALIVE, pack( "i", 1 ) )
      or croak sprintf( "setsockopt SO_KEEPALIVE: %s (%d)", $ERRNO, $ERRNO );

    # BSD/macOS:
    $sock->setsockopt( SOL_SOCKET, SO_NOSIGPIPE, pack( "i", 1 ) )
      or croak sprintf( "setsockopt SO_NOSIGPIPE: %s (%d)", $ERRNO, $ERRNO );
    if defined &Socket::SO_NOSIGPIPE;

    $self->{_connecting} = $sock;

    return;
} ## end sub _connect_start

sub _connect_finish {
    local $ERRNO = 0;
    my $so_error = $sock->getsockopt( SOL_SOCKET, SO_ERRNO );
    if ( !defined $so_error ) {
        croak sprintf( "getsockopt SO_ERRNO: %s (%d)", $ERRNO, $ERRNO );
    }
    $ERRNO = $so_error;

    return if $!{EAGAIN};

    if ( $ERRNO ) {
        if ( $!{EADDRNOTAVAIL} ) {
            my $err = Zonemaster::Engine::Async::TransientError->new( $ERRNO );
            return $self->_flush_with_error( $err );
        }
        elsif ( $!{ECONNREFUSED} || $!{EHOSTUNREACH} || $!{ENETUNREACH} || $!{ETIMEDOUT} ) {
            $self->disconnect;

            my $err = Zonemaster::Engine::Async::AddressError->new( $ERRNO );
            return $self->_flush_with_error( $err );
        }

        croak sprintf( "SOL_SOCKET/SO_ERROR: %s (%d)", $ERRNO, $ERRNO );
    }

    $self->{_socket} = undef $self->{_connecting};

    return;
} ## end sub _connect_finish

1;
