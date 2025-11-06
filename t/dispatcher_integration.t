# t/async_dispatcher_timeout.t
use v5.26;
use strict;
use Test::More;

use Errno qw( ETIMEDOUT );
use IO::Socket::INET;
use Log::Any::Adapter qw( MonoTimeStderr );
use Test::Nameserver;
use Time::HiRes qw( clock_gettime CLOCK_MONOTONIC sleep );

use Zonemaster::Engine::Async::Dispatcher;
use Zonemaster::Engine::Async::UDPTransport;
use Zonemaster::Engine::Async::Query;

my ( $ns, $server_port ) = Test::Nameserver::start(
    mode     => 'delay_second',
    delay_ms => 600,
);

END {
    $ns->stop_server
      if defined $ns;
}

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

done_testing();
