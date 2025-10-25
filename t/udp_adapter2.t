#!perl
use v5.26;
use warnings;
use Test::More;

use English;
use Errno      qw( EINTR EAGAIN EWOULDBLOCK );
use List::Util qw( pairmap );
use Mock::Behavior;
use Test::Differences qw( eq_or_diff );

use Zonemaster::Engine::Async::Query;
use Zonemaster::Engine::Async::UDPAdapter;

sub expect_recv_errno {
    my ( $errno, $name ) = @_;

    return {
        name   => $name,
        method => 'recv',
        args   => [ \'', 65535 ],
        code   => sub { $ERRNO = $errno; () },
    };
}

sub expect_recv_response {
    my ( $server, $message, $name ) = @_;

    return {
        name   => $name,
        method => 'recv',
        args   => [ \'', 65535 ],
        code   => sub {
            $_[0]->$* = $message;
            $server;
        },
    };
}

sub expect_recv_packet {
    my ( $query, $name ) = @_;

    my $server  = $query->{server};
    my $message = dns_msg( $query->%* );

    return expect_recv_response( $server, $message, $name );
}

sub expect_send_errno {
    my ( $query, $errno, $name ) = @_;

    my $server  = $query->{server};
    my $message = dns_msg( $query->%* );

    return {
        method => 'send',
        args   => [ $message, 0, $server ],
        code   => sub { $ERRNO = $errno; () },
    };
}

sub expect_send_packet {
    my ( $query, $name ) = @_;

    my $message = dns_msg( $query->%* );

    return {
        method => 'send',
        args   => [ $message, 0, $query->{server} ],
        code   => sub { length $message },
    };
}

sub dns_request {
    my ( %args ) = @_;

    my $qid     = delete $args{qid};
    my $message = Zonemaster::Engine::Async::Query->new( %args )->mk_wire( $qid );

    return [ $args{server}, $message ];
}

sub dns_response {
    my ( %args ) = @_;

    my $qid     = delete $args{qid};
    my $message = Zonemaster::Engine::Async::Query->new( %args )->mk_wire( $qid );

    return [ $args{server}, $message, 0 ];
}

sub empty_response {
    my ( $server ) = @_;
    return [ $server, \'', 0 ];
}

sub errno_result {
    my ( $errno ) = @_;
    return [ undef, undef, $errno ];
}

sub dns_msg {
    my ( %args ) = @_;
    my $qid = delete $args{qid};
    return Zonemaster::Engine::Async::Query->new( %args )->mk_wire( $qid );
}

my $SOCKET     = Mock::Behavior->new;
my %QUERY_1    = ( qid => 1, server => '192.0.2.1', qname => '1.test', qtype => 'SOA',  qclass => 'IN' );
my %QUERY_2    = ( qid => 2, server => '192.0.2.2', qname => '2.test', qtype => 'NS',   qclass => 'IN' );
my %QUERY_3    = ( qid => 3, server => '192.0.2.3', qname => '3.test', qtype => 'A',    qclass => 'IN' );
my %QUERY_4    = ( qid => 4, server => '192.0.2.4', qname => '4.test', qtype => 'AAAA', qclass => 'IN' );
my %RESPONSE_1 = ( %QUERY_1, qr => 1 );
my %RESPONSE_2 = ( %QUERY_2, qr => 1 );
my %RESPONSE_3 = ( %QUERY_3, qr => 1 );
my %RESPONSE_4 = ( %QUERY_4, qr => 1 );

sub test_wants {
    my ( $adapter, $args, $name ) = @_;

    my $expect = {
        want_read => [
            $args->{read} ? ( $SOCKET )
            : ()
        ],
        want_write => [
            $args->{write} ? ( $SOCKET )
            : ()
        ],
    };

    my $got = {
        want_read  => [ $adapter->want_read ],
        want_write => [ $adapter->want_write ],
    };

    eq_or_diff( $got, $expect, $name );

    return;
} ## end sub test_wants

my $adapter = Zonemaster::Engine::Async::UDPAdapter->new( $SOCKET );
test_wants( $adapter, {}, 'should not want anything upon construction' );

subtest 'enqueue queries' => sub {
    $adapter->enqueue( %QUERY_1, server => '192.0.2.1' );
    $adapter->enqueue( %QUERY_2, server => '192.0.2.2' );
    $adapter->enqueue( %QUERY_3, server => '192.0.2.3' );
    $adapter->enqueue( %QUERY_4, server => '192.0.2.4' );

    test_wants( $adapter, { write => 1 }, 'should want write on single socket for multiple messages' );
};

subtest 'on_writable handles EWOULDBLOCK' => sub {
    $SOCKET->append_script(    #
        expect_send_errno( {%QUERY_1}, &EWOULDBLOCK, 'attempt to send query 1' ),
    );

    $adapter->on_writable();

    $SOCKET->ok_done( 'no more attempts to send after EWOULDBLOCK' );
    test_wants( $adapter, { write => 1 }, 'should still want write' );
};

subtest 'on_writable handles EAGAIN' => sub {
    $SOCKET->append_script(    #
        expect_send_errno( {%QUERY_1}, &EAGAIN, 'attempt to send query 1' ),
    );

    $adapter->on_writable();

    $SOCKET->ok_done( 'no more attempts to send after EAGAIN' );
    test_wants( $adapter, { write => 1 }, 'should still want write' );
};

subtest 'on_writable handles EINTR' => sub {
    $SOCKET->append_script(
        expect_send_errno( {%QUERY_1}, &EINTR,       'attempt to send query 1' ),
        expect_send_errno( {%QUERY_1}, &EWOULDBLOCK, 'retry after EINTR' ),
    );

    $adapter->on_writable();

    $SOCKET->ok_done( 'no more attempts to send after EWOULDBLOCK' );
    test_wants( $adapter, { write => 1 }, 'should still want write' );
};

subtest 'on_writable sends request' => sub {
    $SOCKET->append_script(
        expect_send_packet( {%QUERY_1}, 'send query 1' ),
        expect_send_errno( {%QUERY_2}, &EWOULDBLOCK, 'attempt to send query 2' ),
    );

    $adapter->on_writable();

    $SOCKET->ok_done( 'no more attempt to write after EWOULDBLOCK' );
    test_wants( $adapter, { write => 1, read => 1 }, 'should still want write, but now also read' );
};

subtest 'on_writable sends multiple requests' => sub {
    $SOCKET->append_script(
        expect_send_packet( {%QUERY_2}, 'send query 2' ),
        expect_send_packet( {%QUERY_3}, 'send query 3' ),
        expect_send_packet( {%QUERY_4}, 'send query 4' ),
    );

    $adapter->on_writable();

    $SOCKET->ok_done( 'should not attempt to write after sending all requests' );
    test_wants( $adapter, { read => 1 }, 'should want read, but not write after sending all requests' );
};

subtest 'on_readable handles EWOULDBLOCK' => sub {
    $SOCKET->append_script(    #
        expect_recv_errno( &EWOULDBLOCK, 'return on EWOULDBLOCK' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles EAGAIN' => sub {
    $SOCKET->append_script(    #
        expect_recv_errno( &EAGAIN, 'return on EAGAIN' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles EINTR' => sub {
    $SOCKET->append_script(    #
        expect_recv_errno( &EINTR,       'retry on EINTR' ),
        expect_recv_errno( &EWOULDBLOCK, 'nothing more to recv, presently' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles empty response' => sub {
    $SOCKET->append_script(    #
        expect_recv_response( '192.0.2.4', '', 'ignore empty response' ),
        expect_recv_errno( &EWOULDBLOCK, 'nothing more to recv, presently' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles response with QR=0' => sub {
    $SOCKET->append_script(    #
        expect_recv_packet( { %RESPONSE_4 =>, qr => 0 }, 'ignore response with QR=0' ),
        expect_recv_errno( &EWOULDBLOCK, 'nothing more to recv, presently' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles response with unrecognized QID' => sub {
    $SOCKET->append_script(    #
        expect_recv_packet( { %RESPONSE_4, qid => 1 }, 'ignore response with unrecognized QID' ),
        expect_recv_errno( &EWOULDBLOCK, 'nothing more to recv, presently' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles response with unrecognized QNAME' => sub {
    $SOCKET->append_script(    #
        expect_recv_packet( { %RESPONSE_4, qname => '1.test' }, 'ignore response with unrecognized QNAME' ),
        expect_recv_errno( &EWOULDBLOCK, 'nothing more to recv, presently' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles response with unrecognized QTYPE' => sub {
    $SOCKET->append_script(    #
        expect_recv_packet( { %RESPONSE_4, qtype => 'SOA' }, 'ignore response with unrecognized QTYPE' ),
        expect_recv_errno( &EWOULDBLOCK, 'nothing more to recv, presently' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles response with unrecognized QCLASS' => sub {
    $SOCKET->append_script(    #
        expect_recv_packet( { %RESPONSE_4, qclass => 'CH' }, 'ignore response with unrecognized QCLASS' ),
        expect_recv_errno( &EWOULDBLOCK, 'nothing more to recv, presently' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles response with unrecognized server' => sub {
    $SOCKET->append_script(    #
        expect_recv_packet( { %RESPONSE_4, server => '192.0.2.1' }, 'ignore response with unrecognized server' ),
        expect_recv_errno( &EWOULDBLOCK, 'nothing more to recv, presently' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles responses' => sub {
    $SOCKET->append_script(
        expect_recv_packet( {%RESPONSE_1}, 'accept one response' ),
        expect_recv_errno( &EWOULDBLOCK, 'return on EWOULDBLOCK' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    test_wants( $adapter, { read => 1 }, 'should want to read more responses' );
    eq_or_diff \@responses, [ '192.0.2.1', dns_msg( %RESPONSE_1 ) ];
};

subtest 'on_readable handles multiple responses' => sub {
    $SOCKET->append_script(
        expect_recv_packet( {%RESPONSE_3}, 'accept one response' ),
        expect_recv_packet( {%RESPONSE_2}, 'accept another response' ),
        expect_recv_errno( &EWOULDBLOCK, 'return on EWOULDBLOCK' ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    test_wants( $adapter, { read => 1 }, 'should want to read more responses' );
    eq_or_diff \@responses, [ '192.0.2.3', dns_msg( %RESPONSE_3 ), '192.0.2.2', dns_msg( %RESPONSE_2 ) ];
};

subtest 'on_readable stops waiting to read after last response' => sub {
    $SOCKET->append_script(    #
        expect_recv_packet(
            {%RESPONSE_4}, 'accept response with qr=1 and matching (server, qid, qname, qtype, qclass)'
        ),
    );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->ok_done;
    test_wants( $adapter, {}, 'should not want read after receiving all responses' );
    eq_or_diff \@responses, [ '192.0.2.4', dns_msg( %RESPONSE_4 ) ];
};

done_testing;
