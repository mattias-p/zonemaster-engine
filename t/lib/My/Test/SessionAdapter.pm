package My::Test::SessionAdapter;
use v5.26;
use warnings;

use Exporter                   qw( import );
use List::Util                 qw( pairmap );
use My::Test::Msg              qw( $Msg );
use My::Test::TokenAllocator   qw( $Uint16 );
use My::Test::Util             qw( describe );
use Params::ValidationCompiler qw( validation_for );
use Readonly;
use Test2::API    qw( context_do );
use Types::Common qw( ArrayRef ConsumerOf CycleTuple Dict HashRef InstanceOf NonEmptySimpleStr Tuple );

our @EXPORT_OK = qw(
  $Session
);

Readonly my $Session    => ConsumerOf ['Zonemaster::Engine::Async::SessionRole'];
Readonly my $AsyncError => ConsumerOf ['Zonemaster::Engine::Async::ErrorRole'];

sub new {
    my ( $class, $name, $inner ) = @_;

    my $obj = {
        _name  => $name,
        _inner => $inner,
    };

    return bless $obj, $class;
}

sub test_add_request {
    state $top = validation_for(
        name          => 'test_add_request.top',
        return_object => 1,
        params        => {
            args   => { type => HashRef },
            expect => { type => HashRef },
        },
    );

    state $args_v = validation_for(
        name          => 'test_add_request.args',
        return_object => 1,
        params        => {
            msg => { type => $Msg },
        },
    );

    state $expect_v = validation_for(
        name          => 'test_add_request.expect',
        return_object => 1,
        params        => {
            token => { type => $Uint16 },
        },
    );

    my ( $self, %named )  = @_;
    my ( $args, $expect ) = do {
        my $t      = $top->( %named );
        my $args   = $args_v->( %{ $t->args } );
        my $expect = $expect_v->( %{ $t->expect } );
        ( $args, $expect );
    };

    my $token = $self->{_inner}->add_request( $args->msg->to_query );

    my $call     = sprintf( "%s.test_add_request%s", $self->{_name}, describe( $named{args} ) );
    my $got      = describe( { token => $token } );
    my $expected = describe( $named{expect} );

    context_do {
        my $ctx = shift;

        $ctx->ok( $got eq $expected, sprintf( "%s -> %s", $call, $expected ), [ sprintf( "got: %s", $got ), ] );
    };

    return;

} ## end sub test_add_request

use Data::Dumper;

sub test_tick {
    state $top = validation_for(
        name          => 'test_tick.top',
        return_object => 1,
        params        => {
            args   => { type => Dict [] },
            expect => { type => HashRef },
        },
    );

    state $expect_v = validation_for(
        name          => 'test_tick.expect',
        return_object => 1,
        params        => {
            events => { type => ArrayRef [ Dict [ token => $Uint16, event => $Msg | $AsyncError ] ] },
        },
    );

    my ( $self, %named ) = @_;
    my ( $expect ) = do {
        my $t = $top->( %named );
        $expect_v->( %{ $t->expect } );
    };

    my @events = $self->{_inner}->tick();

    @events = pairmap { { token => $a, event => My::Test::Msg->try_from_packet( $b ) } } @events;

    my $call     = sprintf( "%s.tick%s", $self->{_name}, describe( $named{args} ) );
    my $got      = describe( { events => \@events } );
    my $expected = describe( $named{expect} );

    context_do {
        my $ctx = shift;

        my $ok = $got eq $expected;
        $ctx->ok( $ok, sprintf( "%s -> %s", $call, $expected ), );
        if ( !$ok ) {
            $ctx->note( sprintf( "got: %s", $got ) );
        }
    };

    return;

} ## end sub test_tick

1;
