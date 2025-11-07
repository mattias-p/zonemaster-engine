package My::Test::UdpNameserver;
use v5.26;
use warnings;

use IO::Socket::INET           ();
use My::Test::Msg              qw( $Msg );
use My::Test::Util             qw( describe );
use Params::ValidationCompiler qw( validation_for );
use POSIX                      qw( :sys_wait_h );
use Test2::API                 qw( context_do );
use Time::HiRes                qw( time );
use Types::Common              qw( Dict HashRef );
use Zonemaster::Engine::Async  qw( unpack_sockaddr );

sub new {
    my ( $class, $name, $opts ) = @_;

    my $listen = $opts->{listen};

    my $sock = IO::Socket::INET->new(
        LocalAddr => $listen,
        LocalPort => 0,
        Proto     => 'udp',
        ReuseAddr => 1,
    ) or die "server socket: $!";

    my $obj = {
        _name => $name,
        _sock => $sock,
    };

    return bless $obj, $class;
}

sub port {
    my ( $self ) = @_;
    return $self->{_sock}->sockport;
}

sub test_recv {
    state $top = validation_for(
        name          => 'test_add_request.top',
        return_object => 1,
        params        => {
            args   => { type => Dict [] },
            expect => { type => HashRef },
        },
    );

    state $expect_v = validation_for(
        name          => 'test_add_request.expect',
        return_object => 1,
        params        => {
            msg => { type => $Msg },
        },
    );

    my ( $self, %named )  = @_;
    my ( $args, $expect ) = do {
        my $t = $top->( %named );
        $expect_v->( %{ $t->expect } );
    };

    my $msg;
    if ( IO::Select->new( $self->{_sock} )->can_read ) {
        my $buffer = '';
        my $peer   = $self->{_sock}->recv( $buffer, 65535, 0 );
        my ( undef, $ip ) = unpack_sockaddr( $peer );

        $msg = Zonemaster::LDNS::Packet->new_from_wireformat2( $buffer );
        $msg =
          ( defined $msg )
          ? My::Test::Msg->try_from_packet( $msg, $ip )
          : join( ' ', unpack( '(H2)*', $buffer ) );
    }

    my $call     = sprintf( "%s.test_recv%s", $self->{_name}, describe( $named{args} ) );
    my $got      = describe( { msg => $msg } );
    my $expected = describe( $named{expect} );

    context_do {
        my $ctx = shift;

        $ctx->ok( $got eq $expected, sprintf( "%s -> %s", $call, $expected ), [ sprintf( "got: %s", $got ), ] );
    };

    return;

} ## end sub test_recv

=pod
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
=cut

1;
