#!perl
use v5.26;
use warnings;
use Test2::V0;
use Test::NoWarnings 'had_no_warnings';
use File::Basename;
use File::Spec::Functions qw( rel2abs );
use lib dirname( rel2abs( $0 ) );

use Carp qw( confess croak );
use English;
use Errno          qw( EINTR EAGAIN EWOULDBLOCK ENOBUFS EMSGSIZE ENETUNREACH EINVAL ENETDOWN );
use List::Util     qw( pairmap );
use Mock::Scripted qw( new_scripted_mock );
use Test::Deep     qw( ignore );
use Test::Exception;
use TestUtil qw( is_with_context );

use Zonemaster::Engine::Async qw( pack_sockaddr );
use Zonemaster::Engine::Async::Query;
use Zonemaster::Engine::Async::UDPAdapter;

use constant MAX_RECV_HINT => 65535;
use constant DNS_PORT      => 53;

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

    my $sockaddr = pack_sockaddr( $server, DNS_PORT );

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
    my $sockaddr = pack_sockaddr( $query->{server}, DNS_PORT );

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
    my $sockaddr = pack_sockaddr( $query->{server}, DNS_PORT );

    return {
        name    => $name,
        method  => 'send',
        args    => [ $message, 0, $sockaddr ],
        returns => length( $message ),
    };
}

sub prep_send {
    my ( $sut, $ctl, %query ) = @_;

    BAIL_OUT( 'prep: socket script not empty' )
      if !$ctl->is_exhausted();
    BAIL_OUT( 'prep: unexpectedly waiting to send' )
      if $sut->want_write;

    $sut->enqueue( %query );
    $ctl->expect( mk_send_ok( \%query, 'prep: send' ) );
    $sut->on_writable;

    BAIL_OUT( 'prep: query not sent' )
      if !$ctl->is_exhausted();
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
    is_with_context( $got, $expect, $name );

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

            my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
            my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
            $sut->enqueue( %QUERY_1 );
            $ctl->expect( mk_send_err( {%QUERY_1}, $errno, "send(query 1)->$mnemonic" ) );

            throws_ok {
                $sut->on_writable();
            }
            qr/\Q($numeric)\E/, "on_writable should throw on $mnemonic";
            $ctl->done_ok( "socket should receive all expected calls" );
        };
    }
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

            my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
            my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
            prep_send( $sut, $ctl, %QUERY_1 );

            $ctl->expect( mk_recv_err( $errno, "recv()->$mnemonic" ), );
            throws_ok {
                $sut->on_readable();
            }
            qr/\Q($numeric)\E/, "$mnemonic is fatal";

            $ctl->done_ok( "$mnemonic consumed its scripted call" );
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

            my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
            my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
            $sut->enqueue( %QUERY_1 );
            $ctl->expect( mk_send_err( {%QUERY_1}, $errno, "senf(query 1)->$mnemonic" ), );

            $sut->on_writable();

            $ctl->done_ok( "no more attempts to send after $mnemonic" );
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

            my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
            my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
            prep_send( $sut, $ctl, %QUERY_1 );

            $ctl->expect( mk_recv_err( $errno, "recv()->$mnemonic" ) );
            my @responses = pairmap { $a => $b->data } $sut->on_readable();

            $ctl->done_ok( "no more attempts to recv after $mnemonic" );
            test_wants( $sut, { read => 1 }, 'still awaiting responses' );
            is_with_context \@responses, [], 'no responses were accepted';
        };
    }
};

subtest 'on_writable should retry on EINTR' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    $sut->enqueue( %QUERY_1 );

    $ctl->expect( mk_send_err( {%QUERY_1}, &EINTR,       'send(query 1)->EINTR' ) );
    $ctl->expect( mk_send_err( {%QUERY_1}, &EINTR,       'send(query 1)->EINTR' ) );
    $ctl->expect( mk_send_err( {%QUERY_1}, &EINTR,       'send(query 1)->EINTR' ) );
    $ctl->expect( mk_send_err( {%QUERY_1}, &EWOULDBLOCK, 'send(query 1)->EWOULDBLOCK' ), );
    $sut->on_writable();

    $ctl->done_ok( 'no more attempts to send after EWOULDBLOCK' );
    test_wants( $sut, { write => 1 }, 'should still want write' );
};

subtest 'on_readable should retry on EINTR' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_err( &EINTR,       'recv()->EINTR' ) );
    $ctl->expect( mk_recv_err( &EINTR,       'recv()->EINTR' ) );
    $ctl->expect( mk_recv_err( &EINTR,       'recv()->EINTR' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'recv()->EWOULDBLOCK' ) );
    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects empty response' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_data( $QUERY_1{server}, '', 'ignore empty response' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'recv()->EWOULDBLOCK' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects unparsable response' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    my $message = substr( dns_msg( %RESPONSE_1 ), 0, 13 );

    $ctl->expect( mk_recv_data( $QUERY_1{server}, $message, 'reject unparsable response' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects questionless response' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    my $flags   = 0x8000;                                                        # QR=1
    my $message = pack( 'n n n n n n', $RESPONSE_1{qid}, $flags, 0, 0, 0, 0 );

    $ctl->expect( mk_recv_data( $QUERY_1{server}, $message, 'reject questionless response' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects response with QR=0' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qr => 0 }, 'ignore response with QR=0' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects response with deviating QID' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qid => 4 }, 'ignore response with deviating QID' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects mismatched QNAME after matched QID' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qname => '4.test' }, 'ignore response with deviating QNAME' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects mismatched QTYPE after matched QID' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qtype => 'AAAA' }, 'ignore response with deviating QTYPE' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable rejects mismatched QCLASS after matched QID' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qclass => 'CH' }, 'ignore response with deviating QCLASS' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable handles response with deviating server' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, server => $QUERY_4{server} }, 'ignore response with deviating server' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were accepted';
};

subtest 'on_readable accepts case-variant QNAME' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qname => '1.TEST' }, 'case variant' ) );
    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    cmp_ok scalar( @responses ), '==', 2, 'accepted';
    is_with_context \@responses, [ $QUERY_1{server}, dns_msg( %RESPONSE_1, qname => '1.TEST' ) ];
};

subtest 'on_readable accepts TC=1' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPAdapter->new( $socket );
    prep_send( $sut, $ctl, %QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, tc => 1 }, 'truncation' ) );
    my @responses = pairmap { $a => $b->data } $sut->on_readable();

    is_with_context \@responses, [ $QUERY_1{server}, dns_msg( %RESPONSE_1, tc => 1 ) ];
};

my ( $CTL, $SOCKET ) = new_scripted_mock( qw( send recv ) );
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
    $CTL->expect( mk_send_ok( {%QUERY_1}, 'query 1' ) );
    $CTL->expect( mk_send_err( {%QUERY_2}, &EWOULDBLOCK, 'attempt to send query 2' ) );

    $adapter->on_writable();

    $CTL->done_ok( 'no more attempt to write after EWOULDBLOCK' );
    test_wants( $adapter, { write => 3, read => 1 }, 'should still want write, but now also read' );
};

subtest 'on_writable sends multiple requests' => sub {
    $CTL->expect( mk_send_ok( {%QUERY_2}, 'query 2' ) );
    $CTL->expect( mk_send_ok( {%QUERY_3}, 'query 3' ) );
    $CTL->expect( mk_send_ok( {%QUERY_4}, 'query 4' ) );

    $adapter->on_writable();

    $CTL->done_ok( 'should not attempt to write after sending all requests' );
    test_wants( $adapter, { read => 4 }, 'should want read, but not write after sending all requests' );
};

subtest 'on_readable handles responses' => sub {
    $CTL->expect( mk_recv_ok( {%RESPONSE_1}, 'accept one response' ) );
    $CTL->expect( mk_recv_err( &EWOULDBLOCK, 'return on EWOULDBLOCK' ) );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $CTL->done_ok();
    test_wants( $adapter, { read => 3 }, 'should want to read more responses' );
    is_with_context \@responses, [ $QUERY_1{server}, dns_msg( %RESPONSE_1 ) ];
};

subtest 'on_readable handles multiple responses' => sub {
    $CTL->expect( mk_recv_ok( {%RESPONSE_3}, 'accept one response' ) );
    $CTL->expect( mk_recv_ok( {%RESPONSE_2}, 'accept another response' ) );
    $CTL->expect( mk_recv_err( &EWOULDBLOCK, 'return on EWOULDBLOCK' ) );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $CTL->done_ok();
    test_wants( $adapter, { read => 1 }, 'should want to read more responses' );
    is_with_context \@responses, [ $QUERY_3{server}, dns_msg( %RESPONSE_3 ), $QUERY_2{server}, dns_msg( %RESPONSE_2 ) ],
      'responses returned correctly';
};

subtest 'on_readable stops waiting to read after last response' => sub {
    $CTL->expect(
        mk_recv_ok( {%RESPONSE_4}, 'accept response with qr=1 and matching (server, qid, qname, qtype, qclass)' ) );

    my @responses = pairmap { $a => $b->data } $adapter->on_readable();

    $CTL->done_ok();
    test_wants( $adapter, {}, 'should not want read after receiving all responses' );
    is_with_context \@responses, [ $QUERY_4{server}, dns_msg( %RESPONSE_4 ) ];
};

had_no_warnings;
done_testing;
