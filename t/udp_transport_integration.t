#!perl
use v5.26;
use warnings;
use Test::More;

use Log::Any::Adapter ( 'Stderr' );
use IO::Socket::INET;
use Test::Exception;
use Test::Nameserver;
use Time::HiRes qw(usleep time);

use Zonemaster::Engine::Async::Query;
use Zonemaster::Engine::Async::UDPTransport;
use Zonemaster::LDNS::Packet;

# Child responder: copies query, sets QR bit, echoes back
my ( $ns, $srv_port ) = Test::Nameserver::start();

END {
    $ns->stop_server
      if defined $ns;
}

sub to_query {
    my ( %args ) = @_;
    my $qid      = delete $args{qid};
    my $query    = Zonemaster::Engine::Async::Query->new( %args );

    return ( $qid, $query );
}

# ---- Client socket, nonblocking
my $client = IO::Socket::INET->new( Proto => 'udp' )
  or die "client socket: $!";
IO::Handle::blocking( $client, 0 );

# ---- System under test
my $sut = Zonemaster::Engine::Async::UDPTransport->new( $client, $srv_port );

# Two queries
my @cases = (
    { qid => 0x1234, server => '127.0.0.1', qname => 'example.com.', qtype => 'A',    qclass => 'IN' },
    { qid => 0x2233, server => '127.0.0.1', qname => 'example.net.', qtype => 'AAAA', qclass => 'IN' },
);

# Enqueue
for my $c ( @cases ) {
    $sut->enqueue( to_query( $c->%* ) );
}
is( $sut->send_queue_len, 2, 'send_queue_len reflects pending=2' );

# Send
$sut->handle_writable;
is( $sut->send_queue_len, 0, 'pending drained after handle_writable' );

# Poll for responses
my @got;
my $deadline = time() + 3;    # 3s safety
while ( time() < $deadline ) {
    my @responses = $sut->handle_readable;
    push @got, @responses if @responses;
    last if @got == 2;
    usleep 50_000;
}
is( scalar( @got ), 2, 'received two responses' );

# Verify content and order insensitively by qname
my %seen;
for my $pkt ( @got ) {
    my ( $qrr ) = $pkt->question();
    my $name = $qrr->name();
    $seen{ lc $name }++;
}

ok( $seen{'example.com.'} && $seen{'example.net.'}, 'both question names echoed' );

is( $sut->inflight_count, 0, 'no active after responses' );

done_testing();
