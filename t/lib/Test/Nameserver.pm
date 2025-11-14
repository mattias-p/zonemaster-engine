#!perl
package Test::Nameserver;
use v5.26;
use warnings;

use Net::DNS::Nameserver;
use Time::HiRes qw(usleep);
use IPC::ShareLite;

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
    my $port = 15353 + int( rand 1000 );

    my $ns = Net::DNS::Nameserver->new(
        LocalAddr    => '127.0.0.1',
        LocalPort    => $port,
        Verbose      => 0,
        ReplyHandler => sub {
            my ( $qname, $qclass, $qtype, $peerhost, $query, $conn ) = @_;
            $shm->lock;
            my $count = $shm->fetch;
            $count++;
            $shm->store( $count );
            warn "got request $count";

            return if $mode eq 'drop_all';
            return if $mode eq 'drop_once' && $count == 1;

            if ( $mode eq 'delay_second' && $count == 2 ) {
                warn "SLEEPING for $delay_ms ms\n";
                usleep( 1000 * $delay_ms );    # blocks server subprocess only
            }

            warn "sending response $count";
            $shm->unlock;

            # Respond NOERROR with matching ID and question, zero answers.
            # This exercises your transport/dispatcher path without crafting wire bytes.
            return ( 'NOERROR', [], [], [], { aa => 0 }, {} );
        },
    ) or die "Nameserver create failed";

    $ns->start_server( 600 );    # runs server subprocess(es) and returns immediately

    return ( $ns, $port );
} ## end sub start

1;
