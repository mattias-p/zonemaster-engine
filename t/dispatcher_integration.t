# t/async_dispatcher_timeout.t
use v5.26;
use strict;
use Test::More;

use Errno qw( ETIMEDOUT );
use IO::Socket::INET;
use Log::Any::Adapter qw( MonoTimeStderr );
use Time::HiRes       qw( clock_gettime CLOCK_MONOTONIC sleep );

use Zonemaster::Engine::Async::Dispatcher;
use Zonemaster::Engine::Async::UDPTransport;
use Zonemaster::Engine::Async::Query;
use Zonemaster::LDNS::Packet;

# --- UDP test server: reply immediately to first query, reply late to second ---
my $server = IO::Socket::INET->new(
    Proto     => 'udp',
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
) or plan skip_all => 'Cannot create UDP server socket';

$server->blocking( 0 );
my $server_port = $server->sockport;

my $child = fork();
defined $child or plan skip_all => 'fork failed';

if ( $child == 0 ) {
    $SIG{TERM} = sub { exit 0 };
    $SIG{ALRM} = sub { exit 0 };
    alarm 8;    # test safety cap

    my $replied_immediate = 0;
    my ( $late_buf, $late_peer, $late_at );

    while ( 1 ) {
        my $rin = '';
        vec( $rin, fileno( $server ), 1 ) = 1;
        my $n = select( $rin, undef, undef, 0.01 );

        if ( $n ) {
            my $buf  = '';
            my $peer = $server->recv( $buf, 65535 );
            if ( $peer ) {
                my $pkt = Zonemaster::LDNS::Packet->new_from_wireformat2( $buf );
                if ( defined $pkt ) {
                    if ( !$replied_immediate ) {
                        $replied_immediate = 1;
                        $pkt->qr( 1 );
                        my $wire = $pkt->data;
                        $server->send( $wire, 0, $peer );    # immediate response
                    }
                    else {
                        $late_buf  = $buf;
                        $late_peer = $peer;
                        # send this response after dispatcher timeout so it is dropped
                        $late_at = clock_gettime( CLOCK_MONOTONIC ) + 0.6;
                    }
                }
            }
        } ## end if ( $n )

        if ( $late_buf && clock_gettime( CLOCK_MONOTONIC ) >= $late_at ) {
            my $pkt2 = Zonemaster::LDNS::Packet->new_from_wireformat2( $late_buf );
            if ( defined $pkt2 ) {
                $pkt2->qr( 1 );
                my $wire2 = $pkt2->data;
                $server->send( $wire2, 0, $late_peer );    # late response
            }
            $late_buf = undef;                             # only once
        }
    } ## end while ( 1 )
    exit 0;
} ## end if ( $child == 0 )

# --- Client side using Dispatcher + UDPTransport + Query ---

my $exchange_timeout = 0.30;    # seconds; late reply comes at ~0.6s

my $dispatcher = Zonemaster::Engine::Async::Dispatcher->new(
    exchange_timeout  => $exchange_timeout,
    mono_time         => sub { clock_gettime( CLOCK_MONOTONIC ) },
    transport_factory => sub {
        my $client = IO::Socket::INET->new(
            Proto     => 'udp',
            LocalAddr => '127.0.0.1',
        ) or die "Cannot create client UDP socket: $!";
        $client->blocking( 0 );
        return Zonemaster::Engine::Async::UDPTransport->new( $client, $server_port );
    },
);

my $q1 = Zonemaster::Engine::Async::Query->new(
    server => '127.0.0.1',
    qname  => 'example.org',
    qtype  => 'A',
);

my $q2 = Zonemaster::Engine::Async::Query->new(
    server => '127.0.0.1',
    qname  => 'iana.org',
    qtype  => 'A',
);

my $qid1 = $dispatcher->add_request( $q1 );
my $qid2 = $dispatcher->add_request( $q2 );

ok( defined $qid1 && defined $qid2, 'qids allocated' );
ok( $qid1 != $qid2,                 'qids are distinct' );

# Drive the dispatcher until one response arrives or a hard cap is hit
my $cap = clock_gettime( CLOCK_MONOTONIC ) + 2.0;
my @first_res;
while ( clock_gettime( CLOCK_MONOTONIC ) < $cap ) {
    my @r = $dispatcher->poll_responses();
    if ( @r ) { @first_res = @r; last; }
    # no busy sleep needed; poll_responses does select with a timeout
}

is( scalar( @first_res ), 2, 'exactly one response pair returned' );
if ( @first_res == 2 ) {
    my ( $qid, $packet ) = @first_res;
    is( $qid, $qid1, 'response source IP matches server' );
    ok( $packet->qr, 'response has QR=1' );
    my ( $qrr ) = $packet->question();
    ok( defined $qrr, 'response contains one question' );
}

# Wait past the exchange timeout so the other outstanding request expires
sleep 0.40;
my @after_timeout = $dispatcher->poll_responses();
is( scalar( @after_timeout ), 2, 'no responses immediately after timeout window' );
if ( @after_timeout == 2 ) {
    my ( $qid, $packet ) = @after_timeout;
    is( $qid,    $qid2,      'response source IP matches server' );
    is( $packet, &ETIMEDOUT, 'response is ETIMEDOUT' );
}

# Allow the server to send the deliberately late response, then ensure it is discarded
sleep 0.30;
my @late = $dispatcher->poll_responses();
is( scalar( @late ), 0, 'late response discarded (no matching active exchange)' );

# Cleanup server process
kill 'TERM', $child;
waitpid( $child, 0 );

done_testing();
