package My::Test::SessionAdapter;
use v5.26;
use warnings;

use Data::Dump::Filtered       qw( dump_filtered );
use Exporter                   qw( import );
use My::Test::TokenAllocator   qw( $Token );
use Params::ValidationCompiler qw( validation_for );
use Readonly;
use Test2::API    qw( context_do );
use Types::Common qw( ConsumerOf CycleTuple Dict HashRef InstanceOf NonEmptySimpleStr Tuple );

our @EXPORT_OK = qw(
  $Msg
  $Session
);

Readonly my $Msg     => InstanceOf ['Msg'];
Readonly my $Session => ConsumerOf ['Zonemaster::Engine::Async::SessionRole'];

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
            token => { type => $Token },
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

    my $call     = sprintf( "%s.test_add_request%s", $self->{_name}, short( $named{args} ) );
    my $got      = short( { token => $token } );
    my $expected = short( $named{expect} );

    context_do {
        my $ctx = shift;

        $ctx->ok(
            $got eq $expected,
            sprintf( "%s -> %s", $call, $expected ),
            [    #
                sprintf( "expected: %s", $expected ),
                sprintf( "got:      %s", $got ),
            ]
        );
    };

    return;

} ## end sub test_add_request

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
            events => { type => CycleTuple [ $Token, $Msg ] },
        },
    );

    my ( $self, %named ) = @_;
    my ( $expect ) = do {
        my $t = $top->( %named );
        $expect_v->( %{ $t->expect } );
    };

    my @events = $self->{_inner}->tick();

    my $call     = sprintf( "%s.tick%s", $self->{_name}, short( $named{args} ) );
    my $got      = short( { events => \@events } );
    my $expected = short( $named{expect} );

    context_do {
        my $ctx = shift;

        $ctx->ok(
            $got eq $expected,
            sprintf( "%s -> %s", $call, $expected ),
            [    #
                sprintf( "expected: %s", $expected ),
                sprintf( "got:      %s", $got ),
            ]
        );
    };

    return;

} ## end sub test_tick

sub short {
    my ( $hash ) = @_;

    my $filter = sub {
        my ( $ctx, $objref ) = @_;

        return ( $ctx->is_blessed && $objref->can( 'short' ) )
          ? { dump => $objref->short }
          : ();
    };

    return dump_filtered( $hash, $filter );
}

1;
