package Test::Nameserver;
use v5.26;
use warnings;

use Net::DNS::Nameserver;
use Net::DNS::Resolver;
use IPC::ShareLite qw( LOCK_EX );
use Time::HiRes    qw( sleep time );

my $shm = IPC::ShareLite->new(
    -key     => 0x1234,
    -create  => 'yes',
    -destroy => 'no',
) or die $!;

$shm->store( 0 );

# start(mode => 'echo'|'drop_once'|'drop_all'|'delay_second', delay_ms => 600)
# returns ($ns, $port). Call ->stop_server in END or test teardown.
sub start {
    my ( %opt )  = @_;
    my $mode     = $opt{mode}     // 'echo';
    my $delay_ms = $opt{delay_ms} // 0;

    # choose a high, likely-free port once; avoids privileged ports
    my $addr = '127.0.0.1';
    my $port = 15353 + int( rand 1000 );

    my $ns = Net::DNS::Nameserver->new(
        LocalAddr    => $addr,
        LocalPort    => $port,
        Verbose      => 0,
        ReplyHandler => sub {
            my ( $qname, $qclass, $qtype, $peerhost, $query, $conn ) = @_;
            $shm->lock( LOCK_EX );
            my $count = $shm->fetch;
            $count++;
            $shm->store( $count );

            return if $mode eq 'drop_all';
            return if $mode eq 'drop_once' && $count == 1;

            if ( $mode eq 'delay_second' && $count == 2 ) {
                sleep( $delay_ms / 1000.0 );    # blocks server subprocess only
            }

            $shm->unlock;

            # Respond NOERROR with matching ID and question, zero answers.
            # This exercises your transport/dispatcher path without crafting wire bytes.
            return ( 'NOERROR', [], [], [], { aa => 0 }, {} );
        },
    ) or die "Nameserver create failed";

    $ns->start_server( 600 );    # runs server subprocess(es) and returns immediately

    wait_for_dns( addr => $addr, port => $port, tcp => 0 );
    wait_for_dns( addr => $addr, port => $port, tcp => 1 );

    return ( $ns, $port );
} ## end sub start

sub wait_for_dns {
    my ( %opt ) = @_;
    my $addr    = $opt{addr}    // '127.0.0.1';
    my $port    = $opt{port}    // 15353;
    my $timeout = $opt{timeout} // 2.0;
    my $use_tcp = $opt{tcp}     // 0;

    my $res = Net::DNS::Resolver->new(
        nameservers => [$addr],
        port        => $port,
        recurse     => 0,
    );

    # send() uses retry/retrans; tune for fast polling
    $res->retrans( 0.1 );
    $res->retry( 1 );

    # Optional: force TCP instead of UDP
    $res->usevc( 1 ) if $use_tcp;    # TCP "virtual circuit"

    my $deadline = time() + $timeout;
    while ( time() < $deadline ) {
        my $pkt = $res->send( 'example.com', 'SOA' );    # any qname/qtype you expect to answer
        return 1 if $pkt;                                # any response means "ready"
        sleep 0.050;
    }

    die "nameserver not responding within ${timeout}s: " . $res->errorstring . "\n";
} ## end sub wait_for_dns

1;
