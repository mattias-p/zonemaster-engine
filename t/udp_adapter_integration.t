#!perl
use v5.26;
use strict;
use warnings;

use Test::More;
use Test::Exception;
use IO::Socket::INET;
use IO::Handle  ();
use Time::HiRes qw(usleep time);
use Sub::Override;
use Socket qw(inet_aton pack_sockaddr_in);
use POSIX  qw(WNOHANG);
use Log::Any::Adapter ( 'Stderr' );

BEGIN {
    eval {
        require Zonemaster::Engine::Async::UDPAdapter;
        require Zonemaster::Engine::Async::Query;
        require Zonemaster::LDNS::Packet;
        1;
    } or plan skip_all => 'Zonemaster modules not available';
}

# ---- UDP responder on loopback, ephemeral port
my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'udp',
) or die "server socket: $!";

ok( $server, 'server socket created' );

my $srv_port = $server->sockport;

# Child responder: copies query, sets QR bit, echoes back
my $pid = fork();
defined $pid or die "fork failed: $!";
if ( $pid == 0 ) {
    $SIG{TERM} = sub { exit 0 };
    my $buf;
    while ( 1 ) {
        my $peer = recv( $server, $buf, 65535, 0 ) or next;
        my $resp = $buf;
        # Header: ID, FLAGS, QD, AN, NS, AR (12 bytes)
        my ( $id, $flags, $qd, $an, $ns, $ar ) = unpack( 'n6', substr( $resp, 0, 12 ) );
        $flags |= 0x8000;    # set QR
        substr( $resp, 2, 2, pack( 'n', $flags ) );
        # Echo full rest of query unchanged (question + any EDNS)
        send( $server, $resp, 0, $peer );
    }
    exit 0;
}

ok( $pid, 'responder started' );

# ---- Override pack_sockaddr to direct traffic to ephemeral responder port
my $ov = Sub::Override->new;
$ov->replace(
    'Zonemaster::Engine::Async::pack_sockaddr',
    sub {
        my ( $ip, $ignored_port ) = @_;
        return pack_sockaddr_in( $srv_port, inet_aton( $ip ) );
    }
);

# ---- Client socket, nonblocking
my $client = IO::Socket::INET->new( Proto => 'udp' )
  or die "client socket: $!";
IO::Handle::blocking( $client, 0 );

# ---- Adapter under test
my $adapter = Zonemaster::Engine::Async::UDPAdapter->new( $client );

# Two queries
my @cases = (
    { qid => 0x1234, server => '127.0.0.1', name => 'example.com.', type => 'A',    class => 'IN' },
    { qid => 0x2233, server => '127.0.0.1', name => 'example.net.', type => 'AAAA', class => 'IN' },
);

# Enqueue
for my $c ( @cases ) {
    $adapter->enqueue(
        server => $c->{server},
        qid    => $c->{qid},
        qname  => $c->{name},
        qtype  => $c->{type},
        qclass => $c->{class},
    );
}
is( $adapter->want_write, 2, 'want_write reflects pending=2' );

# Send
$adapter->on_writable;
is( $adapter->want_write, 0, 'pending drained after on_writable' );

# Poll for responses
my @got;
my $deadline = time() + 3;    # 3s safety
while ( time() < $deadline ) {
    my @pairs = $adapter->on_readable;
    push @got, @pairs if @pairs;
    last if @got == 4;        # two (ip, packet) pairs
    usleep 50_000;
}
is( scalar( @got ) / 2, 2, 'received two responses' );

# Verify content and order insensitively by qname
my %seen;
for ( my $i = 0 ; $i < @got ; $i += 2 ) {
    my ( $ip, $pkt ) = @got[ $i, $i + 1 ];
    is( $ip, '127.0.0.1', 'response ip is loopback' );

    my ( $qrr ) = $pkt->question();
    my $name = $qrr->name();
    $seen{ lc $name }++;
}

ok( $seen{'example.com.'} && $seen{'example.net.'}, 'both question names echoed' );

is( $adapter->want_read, 0, 'no active after responses' );

# ---- Cleanup
$ov->restore;
kill 'TERM', $pid;
for ( 1 .. 20 ) { last if waitpid( $pid, WNOHANG ) > 0; usleep 50_000 }

done_testing();
