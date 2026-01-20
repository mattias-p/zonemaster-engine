package Test::DNSLoopServer;
use v5.26;
use warnings;

use IO::Socket::INET ();
use POSIX            qw(:sys_wait_h);
use Time::HiRes      qw(time);

# start(
#   mode => 'echo'|
#           'drop_once'|
#           'drop_all'|
#           'wrong_qid'|
#           'delay_second'|
#           'hold_second',
#   delay_ms => 600,
#   control => $fh
# ) -> ($pid, $port)
sub start {
    my ( %opt )  = @_;
    my $mode     = $opt{mode}     // 'echo';
    my $delay_ms = $opt{delay_ms} // 0;        # for delay_second
    my $ctrl_fh  = $opt{control};              # for hold_second

    my $srv = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'udp',
        ReuseAddr => 1,
    ) or die "server socket: $!";
    my $port = $srv->sockport;

    my $pid = fork // die "fork: $!";
    if ( $pid == 0 ) {
        $SIG{TERM} = sub { exit 0 };

        my %seen_peer;
        my ( $buf2, $peer2, $send_at );    # buffered second response

        while ( 1 ) {
            my $rin = '';
            vec( $rin, fileno( $srv ), 1 ) = 1;
            if ( $mode eq 'hold_second' && $ctrl_fh ) {
                vec( $rin, fileno( $ctrl_fh ), 1 ) = 1;
            }

            my $tout = 0.01;
            my $n    = select( $rin, undef, undef, $tout );

            # Control channel release (hold_second)
            if ( $n && $mode eq 'hold_second' && $ctrl_fh && vec( $rin, fileno( $ctrl_fh ), 1 ) ) {
                my $tmp;
                sysread( $ctrl_fh, $tmp, 1 );
                if ( defined $buf2 ) {
                    my $resp = _make_resp( $buf2, 'echo' );
                    send( $srv, $resp, 0, $peer2 );
                    undef $buf2;
                }
            }

            # Network receive
            if ( $n && vec( $rin, fileno( $srv ), 1 ) ) {
                my $buf  = '';
                my $peer = recv( $srv, $buf, 65535, 0 ) or next;

                if ( $mode eq 'drop_all' ) { next; }

                if ( $mode eq 'drop_once' ) {
                    $seen_peer{$peer} //= 0;
                    if ( !$seen_peer{$peer}++ ) { next; }
                }

                if ( $mode eq 'delay_second' || $mode eq 'hold_second' ) {
                    # First message: echo immediately. Second: buffer.
                    $seen_peer{_count} //= 0;
                    $seen_peer{_count}++;
                    if ( $seen_peer{_count} == 1 ) {
                        my $resp = _make_resp( $buf, 'echo' );
                        send( $srv, $resp, 0, $peer );
                    }
                    else {
                        ( $buf2, $peer2 ) = ( $buf, $peer );
                        $send_at = time() + ( $delay_ms / 1000.0 ) if $mode eq 'delay_second';
                    }
                }
                else {
                    my $resp = _make_resp( $buf, $mode );
                    send( $srv, $resp, 0, $peer );
                }
            } ## end if ( $n && vec( $rin, ...))

            # Timed release (delay_second)
            if ( defined $buf2 && $mode eq 'delay_second' && time() >= $send_at ) {
                my $resp = _make_resp( $buf2, 'echo' );
                send( $srv, $resp, 0, $peer2 );
                undef $buf2;
            }
        } ## end while ( 1 )
        exit 0;
    } ## end if ( $pid == 0 )

    return ( $pid, $port );
} ## end sub start

sub stop {
    my ( $pid ) = @_;
    return unless $pid;
    kill 'TERM', $pid;
    1 while waitpid( $pid, WNOHANG ) > 0;
}

# Minimal DNS response: copy ID and question, set QR=1. 'wrong_qid' flips ID.
sub _make_resp {
    my ( $q, $mode ) = @_;
    my ( $id, $flags ) = unpack 'n n', substr( $q, 0, 4 );
    $flags |= 0x8000;
    $id ^= 0x0001 if $mode eq 'wrong_qid';

    my $i = 12;
    while ( 1 ) {
        my $len = ord substr( $q, $i, 1 );
        $i++;
        last if $len == 0;
        $i += $len;
    }
    my $qlen = ( $i + 1 + 4 ) - 12;    # end of QNAME + QTYPE + QCLASS

    my $hdr = pack( 'n6', $id, $flags, 1, 0, 0, 0 );
    return $hdr . substr( $q, 12, $qlen );
}

1;
