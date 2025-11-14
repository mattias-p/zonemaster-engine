#!perl
use v5.26;
use warnings;
use Test::More;

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
    sut => Zonemaster::Engine::Async::TcTcpUpgrade->new(
        Zonemaster::Engine::Async::Dispatcher->new(
            exchange_timeout  => 5,
            qid_allocator     => \&alloc_mock_token,
            select_fn         => \&select,
            transport_factory => sub {
                return Zonemaster::Engine::Async::UDPTransport->new( peerport => $dnsport );
            },
        )
    )
);

test_advances_time 0 => sub {
    test_consumes_tokens [1] => sub {
        $sut->test_add_request(
            args   => { msg   => msg( peer => '127.0.1.53', qname => 'example.', qtype => 'SOA' ) },
            expect => { token => 1 },
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

    $udp_ns->test_send(
        args => { msg => msg( peer => '127.0.0.1', qid => 1, qname => 'example.', qtype => 'SOA', qr => 1, tc => 1 ) },
        expect => {},
    );

    test_consumes_tokens [2] => sub {
        $sut->test_step(
            args   => {},
            expect => { events => [] },
        );
    };
};

=pod
step(
    actor  => 'tcp_ns',
    verb   => 'accept',
    args   => {},
    expect => {},
);

step(
    actor  => 'tcp_ns',
    verb   => 'receive',
    args   => {},
    expect => { msg => msg( peer => '127.0.1.53', qid => 2, qname => 'example.', qtype => 'SOA' ) },
);

step(
    actor  => 'tcp_ns',
    verb   => 'send',
    args   => { msg => msg( peer => '127.0.1.53', qid => 2, qname => 'example.', qtype => 'SOA', qr => 1 ) },
    expect => {},
);
=cut

test_advances_time 0 => sub {
    $sut->test_step(
        args   => {},
        expect => {
            events => [
                {
                    token => 1,
                    event => msg( peer => '127.0.1.53', qid => 2, qname => 'example.', qtype => 'SOA', qr => 1 )
                }
            ]
        },
    );
};

done_testing;
