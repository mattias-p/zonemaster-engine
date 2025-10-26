package Zonemaster::Engine::Async::UDPAdapter;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Errno qw( EINTR EAGAIN EWOULDBLOCK ENOBUFS EBADMSG );
use IO::Socket;

use Zonemaster::Engine::Async qw( pack_sockaddr unpack_sockaddr );

use constant MAX_DGRAM       => 65535;
use constant DNS_HEADER_SIZE => 12;

sub new {
    my ( $class, $socket ) = @_;

    my $obj = {
        socket  => $socket,
        pending => [],        # flattened list of (server ip, wire) pairs
        active  => {},        # hash from IP to hash from QID to the number 1
    };

    return bless $obj, $class;
}

sub enqueue {
    my ( $self, %query ) = @_;

    my $sockaddr        = pack_sockaddr( $query{server}, 53 );
    my $qid             = delete $query{qid};
    my $packet          = Zonemaster::Engine::Async::Query->new( %query )->mk_packet( $qid );
    my ( $question_rr ) = $packet->question();
    my $question        = [ $question_rr->name(), $question_rr->type(), $question_rr->class() ];

    push $self->{pending}->@*,
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

    return scalar( $self->{pending}->@* );
}

sub want_read {
    my ( $self ) = @_;

    return scalar map { keys $_->%* } values $self->{active}->%*;
}

sub on_writable {
    my ( $self ) = @_;

    my $i = 0;

  QUEUE:
    while ( $i <= $self->{pending}->$#* ) {
        my ( $server, $qid, $question, $message ) = $self->{pending}->[$i]->@{qw( sockaddr qid question message )};

        my $message_len = length $message;
        local $ERRNO = 0;
        for ( ; ; ) {
            my $sent = $self->{socket}->send( $message, 0, $server );

            if ( defined $sent ) {
                $self->{active}{$server} //= {};
                $self->{active}{$server}{$qid} = $question;

                $i += 1;
                next QUEUE;
            }

            next       if $!{EINTR};
            last QUEUE if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOBUFS};
            my ( $port, $ip ) = unpack_sockaddr( $server );
            croak sprintf( "send to %s failed: %s:%d (%d)", $ip, $port, $ERRNO, $ERRNO );
        }

    } ## end QUEUE: while ( $i <= $self->{pending...})

    splice $self->{pending}->@*, 0, $i;

    return;
} ## end sub on_writable

sub on_readable {
    my ( $self ) = @_;

    my @responses;
    while ( $self->{active}->%* ) {
        my $buffer   = '';
        my $sockaddr = $self->{socket}->recv( \$buffer, MAX_DGRAM );
        if ( !$sockaddr ) {
            next if $!{EINTR};
            last if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOBUFS};
            croak sprintf( "recv failed: %s (%d)", $ERRNO, $ERRNO );
        }

        next if length $buffer < DNS_HEADER_SIZE;

        my $qid      = unpack( 'n', $buffer );
        my $question = exists $self->{active}{$sockaddr} && $self->{active}{$sockaddr}{$qid};
        redo if !$question;

        my $packet = Zonemaster::LDNS::Packet->new_from_wireformat2( $buffer );
        if ( !defined $packet ) {
            redo if $!{EBADMSG};
            croak sprintf( "parse failed: %s (%d)", $ERRNO, $ERRNO );
        }

        redo if !$packet->qr();
        my ( $qname, $qtype, $qclass ) = $question->@*;

        my ( $question_rr ) = $packet->question();
        redo if !$question_rr;
        redo if $question_rr->type() ne $qtype;
        redo if $question_rr->class() ne $qclass;
        redo if $question_rr->name() ne $qname;

        my ( $port, $ip ) = unpack_sockaddr( $sockaddr );

        push @responses, $ip, $packet;

        delete $self->{active}{$sockaddr}{$qid};
        if ( !$self->{active}{$sockaddr}->%* ) {
            delete $self->{active}{$sockaddr};
        }
    } ## end while ( $self->{active}->...)

    return @responses;
} ## end sub on_readable

1;
