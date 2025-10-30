package Zonemaster::Engine::Async::UDPTransport;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Errno    qw( EINTR EAGAIN EWOULDBLOCK ENOBUFS EBADMSG );
use Log::Any qw( $log );
use IO::Socket;

use Zonemaster::Engine::Async qw( pack_sockaddr unpack_sockaddr );

use constant MAX_RECV_HINT   => 65535;
use constant DNS_HEADER_SIZE => 12;

sub new {
    my ( $class, $socket, $peerport ) = @_;

    $peerport //= 53;

    my $obj = {
        _peerport => $peerport,
        _socket   => $socket,
        _pending  => [],          # flattened list of (server ip, wire) pairs
        _active   => {},          # hash from IP to hash from QID to the number 1
    };

    return bless $obj, $class;
}

sub socket {
    my ( $self ) = @_;

    return $self->{_socket};
}

sub drop {
    my ( $self, $qid ) = @_;

    $self->{_pending}->@* = grep { $_->{qid} != $qid } $self->{_pending}->@*;

    for my $sockaddr ( keys $self->{_active}->%* ) {
        if ( delete $self->{_active}{$sockaddr}{$qid} ) {
            if ( !$self->{_active}{$sockaddr}->%* ) {
                delete $self->{_active}{$sockaddr};
            }
        }
    }

    return;
}

sub enqueue {
    my ( $self, $qid, $query ) = @_;

    my $sockaddr        = pack_sockaddr( $query->server(), $self->{_peerport} );
    my $packet          = $query->mk_packet( $qid );
    my ( $question_rr ) = $packet->question();
    my $question        = [ $question_rr->name(), $question_rr->type(), $question_rr->class() ];

    push $self->{_pending}->@*,
      {
        sockaddr => $sockaddr,
        qid      => $qid,
        question => $question,
        message  => $packet->data,
      };

    return;
}

sub want_write {
    my ( $self ) = @_;

    return scalar( $self->{_pending}->@* );
}

sub want_read {
    my ( $self ) = @_;

    return scalar map { keys $_->%* } values $self->{_active}->%*;
}

sub on_writable {
    my ( $self ) = @_;

    my $i = 0;

  QUEUE:
    while ( $i <= $self->{_pending}->$#* ) {
        my ( $server, $qid, $question, $message ) = $self->{_pending}->[$i]->@{qw( sockaddr qid question message )};

        my $message_len = length $message;
        local $ERRNO = 0;
        for ( ; ; ) {
            my $sent = $self->{_socket}->send( $message, 0, $server );

            if ( defined $sent ) {
                $self->{_active}{$server} //= {};
                $self->{_active}{$server}{$qid} = $question;

                $i += 1;
                next QUEUE;
            }

            next       if $!{EINTR};
            last QUEUE if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOBUFS};
            my ( $port, $ip ) = unpack_sockaddr( $server );
            croak sprintf( "send to %s:%d failed: %s (%d)", $ip, $port, $ERRNO, $ERRNO );
        }

    } ## end QUEUE: while ( $i <= $self->{_pending...})

    splice $self->{_pending}->@*, 0, $i;

    return;
} ## end sub on_writable

sub on_readable {
    my ( $self ) = @_;

    $log->trace( 'on_readable: enter' );

    my @responses;
    while ( $self->{_active}->%* ) {
        $log->tracef( 'on_readable: %d active exchanges', scalar keys $self->{_active}->%* );
        my $buffer   = '';
        my $sockaddr = $self->{_socket}->recv( $buffer, MAX_RECV_HINT );
        if ( !$sockaddr ) {
            if ( $!{EINTR} ) {
                $log->trace( 'on_readable: recv->EINTR; retry' );
                next;
            }
            if ( $!{EWOULDBLOCK} || $!{EAGAIN} || $!{ENOBUFS} ) {
                $log->trace( 'on_readable: recv->EWOULDBLOCK|EAGAIN|ENOBUFS; return' );
                last;
            }
            croak sprintf( "recv failed: %s (%d)", $ERRNO, $ERRNO );
        }

        if ( length $buffer < DNS_HEADER_SIZE ) {
            $log->trace( 'on_readable: incomplete header (%d bytes); retry', length $buffer );
            redo;
        }

        my $qid      = unpack( 'n', $buffer );
        my $question = exists $self->{_active}{$sockaddr} && $self->{_active}{$sockaddr}{$qid};
        if ( !$question ) {
            $log->trace( 'on_readable: no matching request; retry' );
            redo;
        }

        my $packet = Zonemaster::LDNS::Packet->new_from_wireformat2( $buffer );
        if ( !defined $packet ) {
            if ( $!{EBADMSG} ) {
                $log->trace( 'on_readable: parse->EBADMSG; retry' );
                redo;
            }
            croak sprintf( "parse failed: %s (%d)", $ERRNO, $ERRNO );
        }

        if ( !$packet->qr() ) {
            $log->trace( 'on_readable: QR=0; retry' );
            redo;
        }
        my ( $qname, $qtype, $qclass ) = $question->@*;

        my ( $question_rr ) = $packet->question();
        if ( !$question_rr ) {
            $log->trace( 'on_readable: QDCOUNT=0; retry' );
            redo;
        }
        if ( $question_rr->type() ne $qtype ) {
            $log->trace( 'on_readable: QTYPE mismatch; retry' );
            redo;
        }
        if ( $question_rr->class() ne $qclass ) {
            $log->trace( 'on_readable: QCLASS mismatch; retry' );
            redo;
        }
        if ( lc( $question_rr->name() ) ne lc( $qname ) ) {
            $log->trace( 'on_readable: QNAME mismatch; retry' );
            redo;
        }

        my ( $port, $ip ) = unpack_sockaddr( $sockaddr );

        push @responses, $ip, $packet;

        delete $self->{_active}{$sockaddr}{$qid};
        if ( !$self->{_active}{$sockaddr}->%* ) {
            delete $self->{_active}{$sockaddr};
        }
    } ## end while ( $self->{_active}->...)

    $log->tracef( 'on_readable: return %d responses', scalar( @responses ) / 2 );

    return @responses;
} ## end sub on_readable

1;
