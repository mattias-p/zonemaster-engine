#!perl
use v5.26;
use warnings;
use Test::More;

use My::Test::Clock  qw( test_advances_time );
use My::Test::Msg    qw( msg );
use My::Test::Select qw( select );
use My::Test::SessionAdapter;
use My::Test::TokenAllocator qw( alloc_mock_token test_consumes_tokens );
use Zonemaster::Engine::Async::Dispatcher;

my $sut = My::Test::SessionAdapter->new(
    sut => Zonemaster::Engine::Async::Dispatcher->new(
        exchange_timeout => 5,
        qid_allocator    => \&alloc_mock_token,
        select_fn        => \&select,
    )
);

test_consumes_tokens [1] => sub {
    $sut->test_add_request(
        args   => { msg   => msg( qname => 'example.', qtype => 'SOA' ) },
        expect => { token => 1 },
    );
};

$sut->test_tick(
    args   => {},
    expect => { events => [] },
);

=pod
# Receive UDP query with QID=1.
step(
    actor  => 'udp_ns',
    verb   => 'receive',
    args   => {},
    expect => { msg => msg( qid => 1, qname => 'example.com', qtype => 'SOA' ) },
);

# Receive UDP query with QID=1.
step(
    actor  => 'udp_ns',
    verb   => 'send',
    args   => { msg => msg( qid => 1, qname => 'example.com', qtype => 'SOA', qr => 1, tc => 1 ) },
    expect => {},
);
=cut

test_consumes_tokens [2] => sub {
    test_advances_time 0 => sub {
        $sut->test_tick(
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
    expect => { msg => msg( qid => 2, qname => 'example.com', qtype => 'SOA' ) },
);

step(
    actor  => 'tcp_ns',
    verb   => 'send',
    args   => { msg => msg( qid => 2, qname => 'example.com', qtype => 'SOA', qr => 1 ) },
    expect => {},
);
=cut

test_advances_time 0 => sub {
    $sut->test_tick(
        args   => {},
        expect =>
          { events => [ { token => 1, event => msg( qid => 2, qname => 'example.com', qtype => 'SOA', qr => 1 ) } ] },
    );
};

done_testing;
