package Zonemaster::Engine::Async::UDPTransport;

=head1 NAME

Zonemaster::Engine::Async::UDPTransport - Nonblocking UDP transport for DNS queries

=head1 SYNOPSIS

    use IO::Handle       ();
    use IO::Socket::INET ();
    use Zonemaster::Engine::Async::Query;
    use Zonemaster::Engine::Async::UDPTransport;

    # Nonblocking UDP socket (IPv4 or IPv6 works; example shows IPv4)
    my $sock = IO::Socket::INET->new( Proto => 'udp' )
      or die "socket: $!";
    IO::Handle::blocking( $sock, 0 );

    my $tx = Zonemaster::Engine::Async::UDPTransport->new( $sock );

    # Prepare a query and enqueue with a caller-chosen 16-bit QID
    my ( $qid, $query ) = (
        0x1234,
        Zonemaster::Engine::Async::Query->new(
            server => '192.0.2.1',
            qname  => 'example.com.',
            qtype  => 'A',
            qclass => 'IN',
        )
    );
    $tx->enqueue( $qid, $query );

    # Drive I/O from your event loop
    if ( $tx->want_write ) {
        $tx->on_writable;    # sends as much as possible without blocking
    }

    if ( $tx->want_read ) {
        my @packets = $tx->on_readable;
        for my $packet ( @packets ) {
            # handle $packet
        }
    }

    # Cancel an outstanding exchange by QID
    $tx->drop( $qid );

=head1 DESCRIPTION

C<Zonemaster::Engine::Async::UDPTransport> performs best-effort, nonblocking UDP
send/receive for DNS queries and responses. It keeps a queue of pending
transmissions and a set of active exchanges keyed by query ID.
It validates that incoming responses match the original question before returning
them to the caller.

This module does not implement timers, retries, or retransmission. Integrate it
with a reactor to poll the underlying socket and call C<on_writable> and
C<on_readable> when appropriate.

=cut

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

=head1 CONSTRUCTOR

=head2 new( $socket, $peerport = 53 )

Create a transport over an already created nonblocking datagram socket.

=over 4

=item * C<$socket> - An L<IO::Socket> object supporting C<send> and C<recv>.
The caller is responsible to set the socket to nonblocking mode.

=item * C<$peerport> - Destination port used for all sends. Default 53.

=back

=cut

sub new {
    my ( $class, $socket, $peerport ) = @_;

    $peerport //= 53;

    my $obj = {
        _peerport => $peerport,
        _socket   => $socket,
        _pending  => [],          # an array of hashes with keys {qid, question, message}
        _active   => {},          # hash from QID to [sockaddr, qname, qtype, qclass] arrayref
    };

    return bless $obj, $class;
}

=head1 METHODS

=head2 socket( )

Return the underlying socket object.

=cut

sub socket {
    my ( $self ) = @_;

    return $self->{_socket};
}

=head2 enqueue( $qid, $query )

Enqueue a DNS query for sending.

=over 4

=item * C<$qid> - 16-bit query ID chosen by the caller.

=item * C<$query> - A L<Zonemaster::Engine::Async::Query> describing
the header and contents of the query, as well as the IP address of the
destination for the query.

=back

No network I/O happens until C<on_writable> is called.

=cut

sub enqueue {
    my ( $self, $qid, $query ) = @_;

    my $dst_addr        = pack_sockaddr( $query->server(), $self->{_peerport} );
    my $packet          = $query->mk_packet( $qid );
    my ( $question_rr ) = $packet->question();
    my $question        = [ $dst_addr, $question_rr->name(), $question_rr->type(), $question_rr->class() ];

    push $self->{_pending}->@*,
      {
        qid      => $qid,
        question => $question,
        message  => $packet->data,
      };

    return;
}

=head2 drop( $qid )

Cancel any pending or active exchange matching C<$qid>. Safe to call even if the
ID is unknown.

=cut

sub drop {
    my ( $self, $qid ) = @_;

    $self->{_pending}->@* = grep { $_->{qid} != $qid } $self->{_pending}->@*;
    delete $self->{_active}{$qid};

    return;
}

=head2 want_write( )

Return the count of pending datagrams waiting to be sent. Nonzero means
C<on_writable> may make progress.

=cut

sub want_write {
    my ( $self ) = @_;

    return scalar( $self->{_pending}->@* );
}

=head2 want_read( )

Return the count of outstanding active exchanges. Nonzero means C<on_readable> may yield
responses.

=cut

sub want_read {
    my ( $self ) = @_;

    return scalar keys $self->{_active}->%*;
}

=head2 on_writable( )

Attempt to send all pending datagrams until the socket would block or the queue
is empty. Internally retries C<EINTR>. On C<EAGAIN>, C<EWOULDBLOCK>, or
C<ENOBUFS> it stops and leaves the remaining items queued. On other send
failures it C<croak>s.

Returns nothing.

=cut

sub on_writable {
    my ( $self ) = @_;

    my $i = 0;

  QUEUE:
    while ( $i <= $self->{_pending}->$#* ) {
        my ( $qid, $question, $message ) =
          $self->{_pending}[$i]->@{qw( qid question message )};
        my $dst_addr = $question->[0];

        local $ERRNO = 0;
        for ( ; ; ) {
            my $sent = $self->{_socket}->send( $message, 0, $dst_addr );

            if ( defined $sent ) {
                $self->{_active}{$qid} = $question;

                $i += 1;
                next QUEUE;
            }

            next       if $!{EINTR};
            last QUEUE if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{ENOBUFS};
            my ( $port, $ip ) = unpack_sockaddr( $dst_addr );
            croak sprintf( "send to %s:%d failed: %s (%d)", $ip, $port, $ERRNO, $ERRNO );
        }

    } ## end QUEUE: while ( $i <= $self->{_pending...})

    splice $self->{_pending}->@*, 0, $i;

    return;
} ## end sub on_writable

=head2 on_readable( ) -> @packets

Read and validate as many UDP datagrams as are immediately available and match
active exchanges. Returns a list of L<Zonemaster::LDNS::Packet> objects. Order
follows arrival.

Behavior:

=over 4

=item * Retries C<recv> on C<EINTR>.

=item * Returns immediately on C<EAGAIN>, C<EWOULDBLOCK>, or C<ENOBUFS> with
whatever responses were collected so far.

=item * Extracts QID and finds a matching active exchange for that source
address.

=item * C<croak>s on any other C<recv> failure and any other parse failure.

=item * Discards datagrams rejected by the L</VALIDATION RULES>.

=item * On a valid match, returns the parsed packet and removes that QID from
the active set.

=back

=head1 VALIDATION RULES

An incoming datagram is accepted only if all of the following hold:

=over 4

=item * The datagram can be parsed as a DNS message.

=item * Source address (IP and port) equals what the query was sent to.

=item * QID matches a tracked exchange for that source.

=item * C<QR=1> and C<QDCOUNT=1>.

=item * Question section matches the original: C<QTYPE>, C<QCLASS>, and
case-insensitive C<QNAME>.

=back

=cut

sub on_readable {
    my ( $self ) = @_;

    my @responses;
    while ( $self->{_active}->%* ) {
        my $buffer   = '';
        my $src_addr = $self->{_socket}->recv( $buffer, MAX_RECV_HINT );
        if ( !$src_addr ) {
            if ( $!{EINTR} ) {
                $log->trace( 'on_readable: recv->EINTR; retry' );
                next;
            }
            if ( $!{EWOULDBLOCK} || $!{EAGAIN} || $!{ENOBUFS} ) {
                $log->trace( 'on_readable: recv->EWOULDBLOCK|EAGAIN; return' );
                last;
            }
            croak sprintf( "recv failed: %s (%d)", $ERRNO, $ERRNO );
        }

        if ( length $buffer < DNS_HEADER_SIZE ) {
            $log->tracef( 'on_readable: incomplete header (%d bytes); retry', length $buffer );
            redo;
        }

        my $qid      = unpack( 'n', $buffer );
        my $question = $self->{_active}{$qid};
        if ( !$question ) {
            $log->trace( 'on_readable: no matching QID; retry' );
            redo;
        }

        my ( $dst_addr, $qname, $qtype, $qclass ) = $question->@*;

        if ( $dst_addr ne $src_addr ) {
            $log->trace( 'on_readable: no matching QID/server; retry' );
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

        my @question_rrs = $packet->question();
        if ( @question_rrs != 1 ) {
            $log->tracef( 'on_readable: QDCOUNT=%d; retry', scalar @question_rrs );
            redo;
        }
        if ( $question_rrs[0]->type() ne $qtype ) {
            $log->trace( 'on_readable: QTYPE mismatch; retry' );
            redo;
        }
        if ( $question_rrs[0]->class() ne $qclass ) {
            $log->trace( 'on_readable: QCLASS mismatch; retry' );
            redo;
        }
        if ( lc( $question_rrs[0]->name() ) ne lc( $qname ) ) {
            $log->trace( 'on_readable: QNAME mismatch; retry' );
            redo;
        }

        push @responses, $packet;

        delete $self->{_active}{$qid};
    } ## end while ( $self->{_active}->...)

    return @responses;
} ## end sub on_readable

=head1 LOGGING

Uses L<Log::Any> at C<trace> level with concise messages for state changes,
retries, and rejects. No logs are emitted on the fast path when nothing unusual
happens.

=head1 INTEGRATION NOTES

=over 4

=item * You must manage timers, timeouts, and retransmissions externally.

=item * Provide a nonblocking UDP socket. IPv4 and IPv6 are supported.

=item * Use C<want_write> and C<want_read> to decide when to call the
corresponding handlers from your event loop.

=item * QIDs are caller-managed. Ensure QID uniqueness across all outstanding
queries for this instance.

=back

=cut

1;
