package Zonemaster::Engine::Async::UDPAdapter;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use IO::Socket;

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

    my $server          = $query{server};
    my $qid             = delete $query{qid};
    my $packet          = Zonemaster::Engine::Async::Query->new( %query )->mk_packet( $qid );
    my ( $question_rr ) = $packet->question();
    my $question        = [ $question_rr->name(), $question_rr->type(), $question_rr->class() ];

    push $self->{pending}->@*, ( $server, $qid, $question, $packet->data );

    return;
}

sub want_write {
    my ( $self ) = @_;

    return $self->{pending}->@* > 0
      ? $self->{socket}
      : ();
}

sub want_read {
    my ( $self ) = @_;

    return $self->{active}->%* > 0
      ? $self->{socket}
      : ();
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
            croak sprintf( "send to %s failed: %s", $server, $ERRNO );
        }

    } ## end QUEUE: while ( $i < $self->{pending...})

    $self->{pending}->@* = $self->{pending}->@[ $i .. $self->{pending}->$#* ];

    return;
} ## end sub on_writable

sub on_readable {
    my ( $self ) = @_;

    my @responses;
    while ( $self->{active}->%* ) {
        my $buffer = '';
        my $server = $self->{socket}->recv( \$buffer, 65535 );
        if ( $server ) {
            next if length $buffer < 12;

            my $qid      = unpack( 'n', $buffer );
            my $question = exists $self->{active}{$server} && $self->{active}{$server}{$qid};
            redo if !$question;

            my $packet = Zonemaster::LDNS::Packet->new_from_wireformat2( $buffer );
            redo if !$packet->qr();
            my ( $qname, $qtype, $qclass ) = $question->@*;

            my ( $question_rr ) = $packet->question();
            redo if !$question_rr;
            redo if $question_rr->type() ne $qtype;
            redo if $question_rr->class() ne $qclass;
            redo if $question_rr->name() ne $qname;

            push @responses, $server, $packet;

            delete $self->{active}{$server}{$qid};
            if ( !$self->{active}{$server}->%* ) {
                delete $self->{active}{$server};
            }

            next;
        } ## end if ( $server )
        next if $!{EINTR};
        last if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOBUFS};
        croak sprintf( "recv failed: %s", $ERRNO );
    } ## end while ( $self->{active}->...)

    return @responses;
} ## end sub on_readable

1;
