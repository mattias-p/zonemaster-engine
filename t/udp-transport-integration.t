#!perl

=head1 NAME

udp-transport-integration.t - Verify UDPTransport integration with a real UDP socket

=cut

use v5.26;
use warnings;
use lib 't';
use lib 't/lib';
use Test::More;
use lib 't';
use lib 't/lib';

use Errno qw( EAGAIN EWOULDBLOCK );
use Log::Any::Adapter ( 'Stderr' );
use IO::Socket::INET;
use Test::Differences;
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
my $client = IO::Socket::INET->new(
    Proto    => 'udp',
    PeerHost => '127.0.0.1',
    PeerPort => $srv_port,
    Blocking => 0,
) or die "client socket: $!";

# ---- System under test
my $sut = Zonemaster::Engine::Async::UDPTransport->new( socket => $client );

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
my ( $err1, @responses1 ) = $sut->handle_writable;
eq_or_diff {
    err       => $err1,
    responses => \@responses1,
  },
  {
    err       => undef,
    responses => [],
  },
  'no socket-level error and no terminated tasks';
is( $sut->send_queue_len, 0, 'pending drained after handle_writable' );

# Poll for responses
my @got;
my $deadline = time() + 3;    # 3s safety
while ( time() < $deadline ) {
    my ( $err, @responses2 ) = $sut->handle_readable;
    $err = 0+ ( $err // 0 );
    BAIL_OUT( sprintf( "unexpected socket-level error: %s (%d)", $err, $err ) )
      if $err != 0 && $err != EWOULDBLOCK && $err != EAGAIN;
    push @got, @responses2;
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
