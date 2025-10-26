package Zonemaster::Engine::Async::UDPAdapter;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use IO::Socket;

use Zonemaster::Engine::Async qw( pack_sockaddr unpack_sockaddr );

use constant MAX_UDP_PAYLOAD => 65507;

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

    push $self->{pending}->@*, ( $sockaddr, $qid, $question, $packet->data );

    return;
}

sub want_write {
    my ( $self ) = @_;

    return scalar( $self->{pending}->@* ) / 4;
}

sub want_read {
    my ( $self ) = @_;

    return scalar map { keys $_->%* } values $self->{active}->%*;
}

sub on_writable {
    my ( $self ) = @_;

    my $i = 0;

  QUEUE:
    while ( $i < $self->{pending}->$#* ) {
        my ( $server, $qid, $question, $message ) = $self->{pending}->@[ $i .. $i + 3 ];

        my $message_len = length $message;
        local $ERRNO = 0;
        for ( ; ; ) {
            my $sent = $self->{socket}->send( $message, 0, $server );

            if ( defined $sent ) {
                if ( $sent != $message_len ) {
                    croak sprintf( "sent %d/%d bytes to %s/UDP", $sent, $message_len, $server );
                }

                my $qid = unpack( 'n', $message );
                $self->{active}{$server} //= {};
                $self->{active}{$server}{$qid} = $question;

                $i += 4;
                next QUEUE;
            }

            next       if $!{EINTR};
            last QUEUE if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOBUFS};
            croak sprintf( "send to %s failed: %s (%d)", $server, $ERRNO, $ERRNO );
        } ## end for ( ; ; )

    } ## end QUEUE: while ( $i < $self->{pending...})

    $self->{pending}->@* = $self->{pending}->@[ $i .. $self->{pending}->$#* ];

    return;
} ## end sub on_writable

sub on_readable {
    my ( $self ) = @_;

    my @responses;
    while ( $self->{active}->%* ) {
        my $buffer   = '';
        my $sockaddr = $self->{socket}->recv( \$buffer, MAX_UDP_PAYLOAD );
        if ( $sockaddr ) {
            next if length $buffer < 12;

            my $qid      = unpack( 'n', $buffer );
            my $question = exists $self->{active}{$sockaddr} && $self->{active}{$sockaddr}{$qid};
            redo if !$question;

            my $packet = Zonemaster::LDNS::Packet->new_from_wireformat2( $buffer );
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

            next;
        } ## end if ( $sockaddr )
        next if $!{EINTR};
        last if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOBUFS};
        croak sprintf( "recv failed: %s (%d)", $ERRNO, $ERRNO );
    } ## end while ( $self->{active}->...)

    return @responses;
} ## end sub on_readable

1;
