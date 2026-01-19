#!perl
use v5.26;
use warnings;
use lib 't';
use lib 't/lib';
use Test2::V0;
#use Test::NoWarnings 'had_no_warnings';

use English;
use Errno          qw( EINTR EAGAIN EWOULDBLOCK ENOBUFS EMSGSIZE ENETUNREACH EINVAL ENETDOWN );
use Mock::Scripted qw( new_scripted_mock );
use Test::Deep     qw( ignore );
use Test::Exception;
use TestUtil qw( is_with_context );

use Zonemaster::Engine::Async qw( pack_sockaddr );
use Zonemaster::Engine::Async::Query;
use Zonemaster::Engine::Async::UDPTransport;

use constant MAX_RECV_BUFSIZE => 65535;
use constant DNS_PORT         => 53;

sub mk_recv_err {
    my ( $errno, $name ) = @_;

    return {
        name   => $name,
        method => 'recv',
        args   => [ ignore(), MAX_RECV_BUFSIZE ],
        do     => sub { $ERRNO = $errno; undef },
    };
}

=head2 mk_recv_data

Create an L<Mock::Scripted/"EXPECTATION HASH"> representing a call to L<IO::Socket/"recv">
that returns a certain message from a certain server.

=cut

sub mk_recv_data {
    my ( $server, $message, $name ) = @_;

    my $sockaddr = pack_sockaddr( $server, DNS_PORT );

    return {
        name   => $name,
        method => 'recv',
        args   => [ ignore(), MAX_RECV_BUFSIZE ],
        do     => sub {
            # Write $message to the buffer argument of IO::Socket::recv
            $_[0] = $message;

            # Return the socket address of the simulated sending server
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

=head2 prep_send

  prep_send( $sut, $ctl, %query );

Test helper that performs the "send" part of an exchange.
The query is sent from the SUT and handled in the mock server.

=cut

sub prep_send {
    my ( $sut, $ctl, %query ) = @_;

    bail_out( 'prep: socket script not empty' )
      if !$ctl->is_exhausted();
    bail_out( 'prep: unexpectedly waiting to send' )
      if $sut->send_queue_len;

    $sut->enqueue( to_query( %query ) );
    $ctl->expect( mk_send_ok( \%query, 'prep: send' ) );
    $sut->handle_writable;

    bail_out( 'prep: query not sent' )
      if !$ctl->is_exhausted();
    bail_out( 'prep: not waiting to receive' )
      if !$sut->inflight_count;
    bail_out( 'prep: unexpectedly waiting to send' )
      if $sut->send_queue_len;

    return;
} ## end sub prep_send

sub dns_msg {
    my ( %args ) = @_;
    my $qid = delete $args{qid};
    return Zonemaster::Engine::Async::Query->new( %args )->mk_wire( $qid );
}

sub test_wants {
    my ( $sut, $args, $name ) = @_;

    my $expect = {
        want_read  => delete $args->{read}  // 0,
        want_write => delete $args->{write} // 0,
    };

    bail_out( 'unrecognized desire: ' . join ', ', sort keys $args->%* )
      if $args->%*;

    my $got = {
        want_read  => $sut->inflight_count,
        want_write => $sut->send_queue_len,
    };

    $name //= sprintf( 'should have %d pending and %d active exchanges', $args->{write} // 0, $args->{read} // 0 );

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    is_with_context( $got, $expect, $name );

    return;
} ## end sub test_wants

sub get_errno {
    my ( $name ) = @_;

    my $cv = Errno->can( $name );
    if ( !$cv ) {
        return ( undef, undef );    # unknown on this OS
    }

    my $errno = $cv->();
    return ( $errno, 0+ $errno );
}

=head2 setup

    my ( $sut, $ctl ) = setup();
    my ( $sut, $ctl ) = setup( \%QUERY_1, \%QUERY_2, ... );

Construct a C<Zonemaster::Engine::Async::UDPTransport> wired to a scripted mock
socket, and optionally pre-load it with one or more queries that are sent
immediately (leaving the transport waiting for responses).

Returns a C<Zonemaster::Engine::Async::UDPTransport> and a
C<Mock::Scripted::Ctl>;

=cut

sub setup {
    my ( @queries ) = @_;

    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPTransport->new( socket => $socket );
    for my $query ( @queries ) {
        prep_send( $sut, $ctl, $query->%* );
    }

    return ( $sut, $ctl );
}

my %QUERY_1    = ( qid => 1, server => '192.0.2.1',   qname => '1.test', qtype => 'SOA',  qclass => 'IN' );
my %QUERY_2    = ( qid => 2, server => '192.0.2.2',   qname => '2.test', qtype => 'NS',   qclass => 'IN' );
my %QUERY_3    = ( qid => 3, server => '192.0.2.3',   qname => '3.test', qtype => 'A',    qclass => 'IN' );
my %QUERY_4    = ( qid => 4, server => '2001:db8::1', qname => '4.test', qtype => 'AAAA', qclass => 'IN' );
my %RESPONSE_1 = ( %QUERY_1, qr => 1 );
my %RESPONSE_2 = ( %QUERY_2, qr => 1 );
my %RESPONSE_3 = ( %QUERY_3, qr => 1 );
my %RESPONSE_4 = ( %QUERY_4, qr => 1 );

sub to_query {
    my ( %args ) = @_;
    my $qid      = delete $args{qid};
    my $query    = Zonemaster::Engine::Async::Query->new( %args );

    return ( $qid, $query );
}

subtest 'errnos causing handle_writable to throw' => sub {
    my @send_fatal_errnos = (
        'EBADF',           # File descriptor should always be valid
        'ENOTSOCK',        # File descriptor should always be a socket
        'EFAULT',          # Buffer and sockaddr arguments should always be valid
        'EDESTADDRREQ',    # Destination address should always be provided
        'EISCONN',         # Destination address should always be expected
    );

    for my $mnemonic ( @send_fatal_errnos ) {
        my ( $errno, $numeric ) = get_errno( $mnemonic );

        subtest $mnemonic => sub {
            plan skip_all => "$mnemonic not defined on this OS"
              if !defined $errno;

            my ( $sut, $ctl ) = setup();

            $sut->enqueue( to_query( %QUERY_1 ) );
            $ctl->expect( mk_send_err( {%QUERY_1}, $errno, "send(query 1)->$mnemonic" ) );

            throws_ok {
                $sut->handle_writable();
            }
            qr/\Q($numeric)\E/, "handle_writable should throw on $mnemonic";
            $ctl->done_ok( "socket should receive all expected calls" );
            #test_wants( $sut, {}, 'failed send should drop exchange' );
        };
    } ## end for my $mnemonic ( @send_fatal_errnos)
};

subtest 'errnos causing handle_readable to throw' => sub {
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

            my ( $sut, $ctl ) = setup( \%QUERY_1 );

            $ctl->expect( mk_recv_err( $errno, "recv()->$mnemonic" ), );
            throws_ok {
                $sut->handle_readable();
            }
            qr/\Q($numeric)\E/, "$mnemonic is fatal";

            $ctl->done_ok( "$mnemonic consumed its scripted call" );
            #test_wants( $sut, { read => 1, write => 1 }, 'failed recv should keep exchange in queue' );
        };
    }
};

subtest 'errnos causing handle_writable to return' => sub {
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

            my ( $sut, $ctl ) = setup();

            $ctl->expect( mk_send_err( {%QUERY_1}, $errno, "send(query 1)->$mnemonic" ), );

            $sut->enqueue( to_query( %QUERY_1 ) );
            $sut->handle_writable();

            $ctl->done_ok( "no more attempts to send after $mnemonic" );
            test_wants( $sut, { write => 1 }, 'should still want write' );
        };
    }
};

subtest 'errnos causing handle_readable to return' => sub {
    my @retry_recv_errnos = qw(
      EAGAIN
      EWOULDBLOCK
    );

    for my $mnemonic ( @retry_recv_errnos ) {
        my ( $errno ) = get_errno( $mnemonic );

        subtest $mnemonic => sub {
            plan skip_all => "$mnemonic not defined on this OS"
              if !defined $errno;

            my ( $sut, $ctl ) = setup( \%QUERY_1 );

            $ctl->expect( mk_recv_err( $errno, "recv()->$mnemonic" ) );
            my @responses = map { $_->data } $sut->handle_readable();

            $ctl->done_ok( "no more attempts to recv after $mnemonic" );
            test_wants( $sut, { read => 1 }, 'still awaiting responses' );
            is_with_context \@responses, [], 'no responses were returned';
        };
    }
};

subtest 'handle_writable should retry on EINTR' => sub {
    my ( $ctl, $socket ) = new_scripted_mock( qw( send recv ) );
    my $sut = Zonemaster::Engine::Async::UDPTransport->new( socket => $socket );
    $sut->enqueue( to_query( %QUERY_1 ) );

    $ctl->expect( mk_send_err( {%QUERY_1}, &EINTR,       'send(query 1)->EINTR' ) );
    $ctl->expect( mk_send_err( {%QUERY_1}, &EINTR,       'send(query 1)->EINTR' ) );
    $ctl->expect( mk_send_err( {%QUERY_1}, &EINTR,       'send(query 1)->EINTR' ) );
    $ctl->expect( mk_send_err( {%QUERY_1}, &EWOULDBLOCK, 'send(query 1)->EWOULDBLOCK' ), );
    $sut->handle_writable();

    $ctl->done_ok( 'no more attempts to send after EWOULDBLOCK' );
    test_wants( $sut, { write => 1 }, 'should still want write' );
};

subtest 'handle_readable should retry on EINTR' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_err( &EINTR,       'recv()->EINTR' ) );
    $ctl->expect( mk_recv_err( &EINTR,       'recv()->EINTR' ) );
    $ctl->expect( mk_recv_err( &EINTR,       'recv()->EINTR' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'recv()->EWOULDBLOCK' ) );
    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable rejects empty response' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_data( $QUERY_1{server}, '', 'ignore empty response' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'recv()->EWOULDBLOCK' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable rejects unparsable response' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    my $message = substr( dns_msg( %RESPONSE_1 ), 0, 13 );

    $ctl->expect( mk_recv_data( $QUERY_1{server}, $message, 'reject unparsable response' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

#had_no_warnings;
done_testing;
exit 0;

subtest 'handle_readable rejects questionless response' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    my $flags   = 0x8000;                                                        # QR=1
    my $message = pack( 'n n n n n n', $RESPONSE_1{qid}, $flags, 0, 0, 0, 0 );

    $ctl->expect( mk_recv_data( $QUERY_1{server}, $message, 'reject questionless response' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable rejects response with QR=0' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qr => 0 }, 'ignore response with QR=0' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable rejects response with deviating QID' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qid => 4 }, 'ignore response with deviating QID' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable rejects mismatched QNAME after matched QID' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qname => '4.test' }, 'ignore response with deviating QNAME' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable rejects mismatched QTYPE after matched QID' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qtype => 'AAAA' }, 'ignore response with deviating QTYPE' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable rejects mismatched QCLASS after matched QID' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qclass => 'CH' }, 'ignore response with deviating QCLASS' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable handles response with deviating server' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, server => $QUERY_4{server} }, 'ignore response with deviating server' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'nothing more to recv, presently' ) );

    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'still awaiting responses' );
    is_with_context \@responses, [], 'no responses were returned';
};

subtest 'handle_readable accepts case-variant QNAME' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, qname => '1.TEST' }, 'case variant' ) );
    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    cmp_ok scalar( @responses ), '==', 1, 'accepted';
    is_with_context \@responses, [ dns_msg( %RESPONSE_1, qname => '1.TEST' ) ], 'response 1 was returned';
};

subtest 'handle_readable accepts TC=1' => sub {
    my ( $sut, $ctl ) = setup( \%QUERY_1 );

    $ctl->expect( mk_recv_ok( { %RESPONSE_1, tc => 1 }, 'truncation' ) );
    my @responses = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    is_with_context \@responses, [ dns_msg( %RESPONSE_1, tc => 1 ) ], 'response 1 was returned';
};

subtest 'cancel ignores unrecognized exhanges' => sub {
    my ( $sut, $ctl ) = setup();

    $sut->cancel( $QUERY_1{qid} );
    test_wants( $sut, {} );
};

subtest 'cancel removes pending write' => sub {
    my ( $sut, $ctl ) = setup();

    $sut->enqueue( to_query( %QUERY_1 ) );
    $sut->enqueue( to_query( %QUERY_2 ) );
    $sut->cancel( $QUERY_1{qid} );
    test_wants( $sut, { write => 1 } );
};

subtest 'cancel removes pending read' => sub {
    my ( $sut, $ctl ) = setup();

    # Enqueue writes
    $sut->enqueue( to_query( %QUERY_1 ) );
    $sut->enqueue( to_query( %QUERY_2 ) );

    # Handle writes
    $ctl->expect( mk_send_ok( \%QUERY_1 ) );
    $ctl->expect( mk_send_ok( \%QUERY_2 ) );
    $sut->handle_writable();
    $ctl->done_ok;

    # Cancel one read
    $sut->cancel( $QUERY_1{qid} );

    # Verify one remaining read
    test_wants( $sut, { read => 1 } );
};

subtest 'a sequence' => sub {
    my ( $sut, $ctl ) = setup();

    test_wants( $sut, {}, 'should not want anything upon construction' );

    note 'enqueue queries';

    $sut->enqueue( to_query( %QUERY_1 ) );
    $sut->enqueue( to_query( %QUERY_2 ) );
    $sut->enqueue( to_query( %QUERY_3 ) );
    $sut->enqueue( to_query( %QUERY_4 ) );

    test_wants( $sut, { write => 4 }, 'should want write on single socket for multiple messages' );

    note 'handle_writable sends request';
    $ctl->expect( mk_send_ok( {%QUERY_1}, 'query 1' ) );
    $ctl->expect( mk_send_err( {%QUERY_2}, &EWOULDBLOCK, 'attempt to send query 2' ) );

    $sut->handle_writable();

    $ctl->done_ok( 'no more attempt to write after EWOULDBLOCK' );
    test_wants( $sut, { write => 3, read => 1 }, 'should still want write, but now also read' );

    note 'handle_writable sends multiple requests';
    $ctl->expect( mk_send_ok( {%QUERY_2}, 'query 2' ) );
    $ctl->expect( mk_send_ok( {%QUERY_3}, 'query 3' ) );
    $ctl->expect( mk_send_ok( {%QUERY_4}, 'query 4' ) );

    $sut->handle_writable();

    $ctl->done_ok( 'should not attempt to write after sending all requests' );
    test_wants( $sut, { read => 4 }, 'should want read, but not write after sending all requests' );

    note 'handle_readable handles responses';
    $ctl->expect( mk_recv_ok( {%RESPONSE_1}, 'accept one response' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'return on EWOULDBLOCK' ) );

    my @responses1 = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 3 }, 'should want to read more responses' );
    is_with_context \@responses1, [ dns_msg( %RESPONSE_1 ) ], 'response 1 was returned';

    note 'handle_readable handles multiple responses';
    $ctl->expect( mk_recv_ok( {%RESPONSE_3}, 'accept one response' ) );
    $ctl->expect( mk_recv_ok( {%RESPONSE_2}, 'accept another response' ) );
    $ctl->expect( mk_recv_err( &EWOULDBLOCK, 'return on EWOULDBLOCK' ) );

    my @responses2 = map { $_->data } $sut->handle_readable();

    $ctl->done_ok();
    test_wants( $sut, { read => 1 }, 'should want to read more responses' );
    is_with_context \@responses2, [ dns_msg( %RESPONSE_3 ), dns_msg( %RESPONSE_2 ) ], 'responses 3 and 2 were returned';

    note 'handle_readable stops waiting to read after last response';
    $ctl->expect(
        mk_recv_ok( {%RESPONSE_4}, 'accept response with qr=1 and matching (server, qid, qname, qtype, qclass)' ) );

    my @responses3 = map { $_->data } $sut->handle_readable();

    is_with_context \@responses3, [ dns_msg( %RESPONSE_4 ) ], 'response 4 was returned';
    $ctl->done_ok();
    test_wants( $sut, {}, 'should not want read after receiving all responses' );
};

#had_no_warnings;
done_testing;
