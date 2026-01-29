#!perl
use v5.26;
use warnings;
use lib 't';
use lib 't/lib';
use Test::More;
use lib 't';
use lib 't/lib';

use My::Test::Clock  qw( test_advances_time );
use My::Test::Msg    qw( msg );
use My::Test::Select qw( select );
use My::Test::SessionAdapter;
use My::Test::TokenAllocator qw( alloc_mock_token test_consumes_tokens );
use My::Test::UdpNameserver;
use Zonemaster::Engine::Async::Dispatcher;
use Zonemaster::Engine::Async::TcTcpUpgrade;

my $udp_ns  = My::Test::UdpNameserver->new( udp_ns => { listen => '127.0.1.53' } );
my $dnsport = $udp_ns->port;

my $sut = My::Test::SessionAdapter->new(
    sut => Zonemaster::Engine::Async::Dispatcher->new(
        exchange_timeout  => 5,
        qid_allocator     => \&alloc_mock_token,
        select_fn         => \&select,
        transport_factory => sub {
            my $socket = IO::Socket::INET->new(
                Proto    => 'udp',
                PeerHost => '127.0.1.53',
                PeerPort => $dnsport,
                Blocking => 0,
            ) or BAIL_OUT( "failed to construct socket: $!" );
            return Zonemaster::Engine::Async::UDPTransport->new( socket => $socket );
        },
    ),
);

test_consumes_tokens [1] => sub {
    $sut->test_add_request(
        args   => { msg   => msg( peer => '127.0.1.53', qname => 'example.', qtype => 'SOA' ) },
        expect => { token => 1 },
    );
};

test_consumes_tokens [2] => sub {
    $sut->test_add_request(
        args   => { msg   => msg( peer => '127.0.1.53', qname => 'a.example.', qtype => 'A' ) },
        expect => { token => 2 },
    );
};

$sut->test_step(
    args   => {},
    expect => { events => [] },
);

$udp_ns->test_recv(
    args   => {},
    expect => { msg => msg( peer => '127.0.0.1', qid => 1, qname => 'example.', qtype => 'SOA' ) },
);

$udp_ns->test_recv(
    args   => {},
    expect => { msg => msg( peer => '127.0.0.1', qid => 2, qname => 'a.example.', qtype => 'A' ) },
);

$udp_ns->test_send(
    args   => { msg => msg( peer => '127.0.0.1', qid => 1, qname => 'example.', qtype => 'SOA', qr => 1 ) },
    expect => {},
);

test_advances_time 0 => sub {
    test_consumes_tokens [] => sub {
        $sut->test_step(
            args   => {},
            expect => {
                events => [
                    {
                        token => 1,
                        event => msg( peer => '127.0.1.53', qid => 1, qname => 'example.', qtype => 'SOA', qr => 1 )
                    }
                ]
            },
        );
    };
};

$udp_ns->test_send(
    args   => { msg => msg( peer => '127.0.0.1', qid => 2, qname => 'a.example.', qtype => 'A', qr => 1 ) },
    expect => {},
);

test_advances_time 0 => sub {
    test_consumes_tokens [] => sub {
        $sut->test_step(
            args   => {},
            expect => {
                events => [
                    {
                        token => 2,
                        event => msg( peer => '127.0.1.53', qid => 2, qname => 'a.example.', qtype => 'A', qr => 1 )
                    }
                ]
            },
        );
    };
};

done_testing;
