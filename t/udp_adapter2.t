#!perl
use v5.26;
use warnings;
use Test::More;
use Test::NoWarnings 'had_no_warnings';

use Carp qw( croak );
use English;
use Errno      qw( EINTR EAGAIN EWOULDBLOCK ENOBUFS EMSGSIZE ENETUNREACH EINVAL ENETDOWN );
use List::Util qw( pairmap );
use Mock::Scripted;
use Test::Deep        qw( ignore );
use Test::Differences qw( eq_or_diff );
use Test::Exception;

use Zonemaster::Engine::Async qw( pack_sockaddr );
use Zonemaster::Engine::Async::Query;
use Zonemaster::Engine::Async::UDPAdapter;

use constant MAX_RECV_HINT => 65535;

sub mk_recv_err {
    my ( $errno, $name ) = @_;

    return {
        name   => $name,
        method => 'recv',
        args   => [ ignore(), MAX_RECV_HINT ],
        do     => sub { $ERRNO = $errno; undef },
    };
}

sub mk_recv_data {
    my ( $server, $message, $name ) = @_;

    my $sockaddr = pack_sockaddr( $server, 53 );

    return {
        name   => $name,
        method => 'recv',
        args   => [ ignore(), MAX_RECV_HINT ],
        do     => sub {
            ${ $_[0] } = $message;
            $sockaddr;
        },
    };
}

sub mk_recv_ok {
    my ( $query, $name ) = @_;

    my $server  = $query->{server};
    my $message = dns_msg( $query->%* );

    return mk_recv_data( $server, $message, $name );
}

sub mk_send_err {
    my ( $query, $errno, $name ) = @_;

    my $message  = dns_msg( $query->%* );
    my $sockaddr = pack_sockaddr( $query->{server}, 53 );

    return {
        name   => $name,
        method => 'send',
        args   => [ $message, 0, $sockaddr ],
        do     => sub { $ERRNO = $errno; undef },
    };
}

sub mk_send_ok {
    my ( $query, $name ) = @_;

    my $message  = dns_msg( $query->%* );
    my $sockaddr = pack_sockaddr( $query->{server}, 53 );

    return {
        name    => $name,
        method  => 'send',
        args    => [ $message, 0, $sockaddr ],
        returns => length( $message ),
    };
}

sub prep_send {
    my ( $sut, $socket, %query ) = @_;

    BAIL_OUT( 'prep: socket script not empty' )
      if !$socket->is_exhausted;
    BAIL_OUT( 'prep: unexpectedly waiting to send' )
      if $sut->want_write;

    $sut->enqueue( %query );
    $socket->expect( mk_send_ok( \%query, 'prep: send' ) );
    $sut->on_writable;

    BAIL_OUT( 'prep: query not sent' )
      if !$socket->is_exhausted;
    BAIL_OUT( 'prep: not waiting to receive' )
      if !$sut->want_read;
    BAIL_OUT( 'prep: unexpectedly waiting to send' )
      if $sut->want_write;

    return;
} ## end sub prep_send

sub dns_msg {
    my ( %args ) = @_;
    my $qid = delete $args{qid};
    return Zonemaster::Engine::Async::Query->new( %args )->mk_wire( $qid );
}

sub test_wants {
    my ( $adapter, $args, $name ) = @_;

    my $expect = {
        want_read  => $args->{read}  // 0,
        want_write => $args->{write} // 0,
    };

    my $got = {
        want_read  => $adapter->want_read,
        want_write => $adapter->want_write,
    };

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    eq_or_diff( $got, $expect, $name );

    return;
}

sub get_errno {
    my ( $name ) = @_;

    my $cv = Errno->can( $name );
    if ( !$cv ) {
        return ( undef, undef );    # unknown on this OS
    }

    my $errno = $cv->();
    return ( $errno, 0+ $errno );
}

my %QUERY_1    = ( qid => 1, server => '192.0.2.1',   qname => '1.test', qtype => 'SOA',  qclass => 'IN' );
my %QUERY_2    = ( qid => 2, server => '192.0.2.2',   qname => '2.test', qtype => 'NS',   qclass => 'IN' );
my %QUERY_3    = ( qid => 3, server => '192.0.2.3',   qname => '3.test', qtype => 'A',    qclass => 'IN' );
my %QUERY_4    = ( qid => 4, server => '2001:db8::1', qname => '4.test', qtype => 'AAAA', qclass => 'IN' );
my %RESPONSE_1 = ( %QUERY_1, qr => 1 );
my %RESPONSE_2 = ( %QUERY_2, qr => 1 );
my %RESPONSE_3 = ( %QUERY_3, qr => 1 );
my %RESPONSE_4 = ( %QUERY_4, qr => 1 );

subtest 'errnos causing on_writable to throw' => sub {
    my @send_fatal_errnos = qw(
      EACCES
      EADDRNOTAVAIL
      EAFNOSUPPORT
      EHOSTUNREACH
      EINVAL
      EMSGSIZE
      ENETDOWN
      ENETUNREACH
      EPERM
    );

    for my $mnemonic ( @send_fatal_errnos ) {
        my ( $errno, $numeric ) = get_errno( $mnemonic );

        subtest $mnemonic => sub {
            plan skip_all => "$mnemonic not defined on this OS"
              if !defined $errno;

            my $socket = Mock::Scripted->new;
            my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
            $sut->enqueue( %QUERY_1 );
            $socket->expect(
                mk_send_err( {%QUERY_1}, $errno, "socket should receive send(query 1), returning $mnemonic" ) );

            throws_ok {
                $sut->on_writable();
            }
            qr/\Q($numeric)\E/, "on_writable should throw on $mnemonic";
            $socket->done_ok( "socket should receive all expected calls" );
        };
    } ## end for my $mnemonic ( @send_fatal_errnos)
};

subtest 'errnos causing on_readable to throw' => sub {
    my @recv_fatal_errnos = qw(
      EINVAL
      ENETDOWN
      ENETUNREACH
    );

    for my $mnemonic ( @recv_fatal_errnos ) {
        my ( $errno, $numeric ) = get_errno( $mnemonic );

        subtest $mnemonic => sub {
            plan skip_all => "$mnemonic not defined on this OS"
              if !defined $errno;

            my $socket = Mock::Scripted->new;
            my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
            prep_send( $sut, $socket, %QUERY_1 );

            $socket->expect( mk_recv_err( $errno, 'attempt to recv' ), );
            throws_ok {
                $sut->on_readable();
            }
            qr/\Q($numeric)\E/, "$mnemonic is fatal";

            $socket->done_ok( "$mnemonic consumed its scripted call" );
        };
    } ## end for my $mnemonic ( @recv_fatal_errnos)
};

subtest 'errnos causing on_writable to return' => sub {
    my @retry_send_errnos = qw(
      EAGAIN
      ENOBUFS
      EWOULDBLOCK
    );

    for my $mnemonic ( @retry_send_errnos ) {
        my ( $errno ) = get_errno( $mnemonic );

        subtest $mnemonic => sub {
            plan skip_all => "$mnemonic not defined on this OS"
              if !defined $errno;

            my $socket = Mock::Scripted->new;
            my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
            $sut->enqueue( %QUERY_1 );
            $socket->expect( mk_send_err( {%QUERY_1}, $errno, 'attempt to send query 1' ), );

            $sut->on_writable();

            $socket->done_ok( "no more attempts to send after $mnemonic" );
            test_wants( $sut, { write => 1 }, 'should still want write' );
        };
    }
};

subtest 'errnos causing on_readable to return' => sub {
    my @retry_recv_errnos = qw(
      EAGAIN
      ENOBUFS
      EWOULDBLOCK
    );

    for my $mnemonic ( @retry_recv_errnos ) {
        my ( $errno ) = get_errno( $mnemonic );

        subtest $mnemonic => sub {
            plan skip_all => "$mnemonic not defined on this OS"
              if !defined $errno;

            my $socket = Mock::Scripted->new;
            my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
            prep_send( $sut, $socket, %QUERY_1 );

            $socket->expect( mk_recv_err( $errno, "return on $mnemonic" ) );
            my @responses = pairmap { $a => $b->data } $sut->on_readable();

            $socket->done_ok( "no more attempts to recv after $mnemonic" );
            test_wants( $sut, { read => 1 }, 'still awaiting responses' );
            eq_or_diff \@responses, [], 'no responses were accepted';
        };
    }
};

subtest 'on_writable should retry on EINTR' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    $sut->enqueue( %QUERY_1 );

    $socket->expect( mk_send_err( {%QUERY_1}, &EINTR,       'attempt to send query 1' ) );
    $socket->expect( mk_send_err( {%QUERY_1}, &EWOULDBLOCK, 'retry after EINTR' ), );
    $sut->on_writable();

    $socket->done_ok( 'no more attempts to send after EWOULDBLOCK' );
    test_wants( $sut, { write => 1 }, 'should still want write' );
};

subtest 'on_readable should retry on EINTR' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect( mk_recv_err( &EINTR,       'retry on EINTR' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );
    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects empty response' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect( mk_recv_data( $QUERY_1{server}, '', 'ignore empty response' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects unparsable response' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    my $message = substr( dns_msg( %RESPONSE_1 ), 0, 13 );

    $socket->expect( mk_recv_data( $QUERY_1{server}, $message, 'ignore unparsable response' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects questionless response' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    my $flags   = 0x8000;                                                        # QR=1
    my $message = pack( 'n n n n n n', $RESPONSE_1{qid}, $flags, 0, 0, 0, 0 );

    $socket->expect( mk_recv_data( $QUERY_1{server}, $message, 'ignore unparsable response' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects response with QR=0' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect( mk_recv_ok( { %RESPONSE_1, qr => 0 }, 'ignore response with QR=0' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects response with deviating QID' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect( mk_recv_ok( { %RESPONSE_1, qid => 4 }, 'ignore response with deviating QID' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects mismatched QNAME after matched QID' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect( mk_recv_ok( { %RESPONSE_1, qname => '4.test' }, 'ignore response with deviating QNAME' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects mismatched QTYPE after matched QID' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect( mk_recv_ok( { %RESPONSE_1, qtype => 'AAAA' }, 'ignore response with deviating QTYPE' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects mismatched QCLASS after matched QID' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect( mk_recv_ok( { %RESPONSE_1, qclass => 'CH' }, 'ignore response with deviating QCLASS' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles response with deviating server' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect(
        mk_recv_ok( { %RESPONSE_1, server => $QUERY_4{server} }, 'ignore response with deviating server' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $socket->done_ok;
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    eq_or_diff \@responses, [], 'no responses were accepted';
};

subtest 'on_readable accepts case-variant QNAME' => sub {
    my $socket = Mock::Scripted->new;
    my $sut    = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $socket, %QUERY_1 );

    $socket->expect( mk_recv_ok( { %RESPONSE_1, qname => '1.TEST' }, 'case variant' ) );
    $socket->expect( mk_recv_err( &EWOULDBLOCK, 'drain' ) );
    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    cmp_ok scalar( @responses ), '==', 2, 'accepted';
    eq_or_diff \@responses, [ $QUERY_1{server}, dns_msg( %RESPONSE_1, qname => '1.TEST' ) ];
};

my $SOCKET  = Mock::Scripted->new;
my $adapter = Zonemaster::Engine::Async::UDPAdapter->new( $SOCKET );
test_wants( $adapter, {}, 'should not want anything upon construction' );

subtest 'enqueue queries' => sub {
    $adapter->enqueue( %QUERY_1 );
    $adapter->enqueue( %QUERY_2 );
    $adapter->enqueue( %QUERY_3 );
    $adapter->enqueue( %QUERY_4 );

    test_wants( $adapter, { write => 4 }, 'should want write on single socket for multiple messages' );
};

subtest 'on_writable sends request' => sub {
    $SOCKET->expect( mk_send_ok( {%QUERY_1}, 'send query 1' ) );
    $SOCKET->expect( mk_send_err( {%QUERY_2}, &EWOULDBLOCK, 'attempt to send query 2' ) );

    $adapter->on_writable();

    $SOCKET->done_ok( 'no more attempt to write after EWOULDBLOCK' );
    test_wants( $adapter, { write => 3, read => 1 }, 'should still want write, but now also read' );
};

subtest 'on_writable sends multiple requests' => sub {
    $SOCKET->expect( mk_send_ok( {%QUERY_2}, 'send query 2' ) );
    $SOCKET->expect( mk_send_ok( {%QUERY_3}, 'send query 3' ) );
    $SOCKET->expect( mk_send_ok( {%QUERY_4}, 'send query 4' ) );

    $adapter->on_writable();

    $SOCKET->done_ok( 'should not attempt to write after sending all requests' );
    test_wants( $adapter, { read => 4 }, 'should want read, but not write after sending all requests' );
};

subtest 'on_readable handles responses' => sub {
    $SOCKET->expect( mk_recv_ok( {%RESPONSE_1}, 'accept one response' ) );
    $SOCKET->expect( mk_recv_err( &EWOULDBLOCK, 'return on EWOULDBLOCK' ) );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->done_ok;
    test_wants( $adapter, { read => 3 }, 'should want to read more responses' );
    eq_or_diff \@responses, [ $QUERY_1{server}, dns_msg( %RESPONSE_1 ) ];
};

subtest 'on_readable handles multiple responses' => sub {
    $SOCKET->expect( mk_recv_ok( {%RESPONSE_3}, 'accept one response' ) );
    $SOCKET->expect( mk_recv_ok( {%RESPONSE_2}, 'accept another response' ) );
    $SOCKET->expect( mk_recv_err( &EWOULDBLOCK, 'return on EWOULDBLOCK' ) );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->done_ok;
    test_wants( $adapter, { read => 1 }, 'should want to read more responses' );
    eq_or_diff \@responses, [ $QUERY_3{server}, dns_msg( %RESPONSE_3 ), $QUERY_2{server}, dns_msg( %RESPONSE_2 ) ];
};

subtest 'on_readable stops waiting to read after last response' => sub {
    $SOCKET->expect(
        mk_recv_ok( {%RESPONSE_4}, 'accept response with qr=1 and matching (server, qid, qname, qtype, qclass)' ) );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $SOCKET->done_ok;
    test_wants( $adapter, {}, 'should not want read after receiving all responses' );
    eq_or_diff \@responses, [ $QUERY_4{server}, dns_msg( %RESPONSE_4 ) ];
};

had_no_warnings;
done_testing;
