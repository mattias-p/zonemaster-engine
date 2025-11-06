#!perl
package Msg;
use v5.26;
use warnings;

use Params::ValidationCompiler qw( validation_for );
use Types::Common              qw( Enum NonEmptySimpleStr );
use Zonemaster::Engine::Async::Query;

sub new {
    my ( $class, %args ) = @_;

    state $check = validation_for(
        name   => 'msg',
        params => {
            qname => { type => NonEmptySimpleStr },
            qtype => { type => Enum [qw( SOA )] },
        },
    );

    $check->( %args );

    my $obj = \%args;

    return bless $obj, $class;
}

sub to_query {
    my ( $self ) = @_;
    return Zonemaster::Engine::Async::Query->new(
        qname  => $self->{qname},
        qtype  => $self->{qtype},
        server => '127.0.0.1'
    );
}

package main;
use v5.26;
use warnings;
use Test::More;

use My::Test::SessionAdapter;
use My::Test::TokenAllocator qw( alloc_mock_token test_consumes_tokens );
use Zonemaster::Engine::Async::Dispatcher;

sub msg {
    return Msg->new( @_ );
}

my $sut = My::Test::SessionAdapter->new(
    sut => Zonemaster::Engine::Async::Dispatcher->new(
        exchange_timeout => 5,
        qid_allocator    => \&alloc_mock_token,
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

step(
    actor  => 'sut',
    verb   => 'tick',
    args   => { _tokens => [2] },
    expect => { events  => [] },
);

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

step(
    actor  => 'sut',
    verb   => 'tick',
    args   => { _tokens => [] },
    expect => { events => [ { token => 1, msg => msg( qid => 2, qname => 'example.com', qtype => 'SOA', qr => 1 ) } ] },
);
=cut

done_testing;
