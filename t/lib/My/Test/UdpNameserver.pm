package My::Test::UdpNameserver;
use v5.26;
use warnings;

use IO::Socket::INET           ();
use My::Test::Msg              qw( $Msg );
use My::Test::Util             qw( describe );
use Params::ValidationCompiler qw( validation_for );
use POSIX                      qw( :sys_wait_h );
use Test2::API                 qw( context_do );
use Time::HiRes                qw( time );
use Types::Common              qw( Dict HashRef );
use Zonemaster::Engine::Async  qw( unpack_sockaddr );

sub new {
    my ( $class, $name, $opts ) = @_;

    my $listen = $opts->{listen};

    my $sock = IO::Socket::INET->new(
        LocalAddr => $listen,
        LocalPort => 0,
        Proto     => 'udp',
        ReuseAddr => 1,
    ) or die "server socket: $!";

    my $obj = {
        _name => $name,
        _sock => $sock,
    };

    return bless $obj, $class;
}

sub port {
    my ( $self ) = @_;
    return $self->{_sock}->sockport;
}

sub test_recv {
    state $top = validation_for(
        name          => 'test_recv.top',
        return_object => 1,
        params        => {
            args   => { type => Dict [] },
            expect => { type => HashRef },
        },
    );

    state $expect_v = validation_for(
        name          => 'test_recv.expect',
        return_object => 1,
        params        => {
            msg => { type => $Msg },
        },
    );

    my ( $self, %named )  = @_;
    my ( $args, $expect ) = do {
        my $t = $top->( %named );
        $expect_v->( %{ $t->expect } );
    };

    my $msg;
    if ( IO::Select->new( $self->{_sock} )->can_read ) {
        my $buffer = '';
        my $peer   = $self->{_sock}->recv( $buffer, 65535, 0 );
        my ( undef, $ip ) = unpack_sockaddr( $peer );

        $msg = Zonemaster::LDNS::Packet->new_from_wireformat2( $buffer );
        $msg =
          ( defined $msg )
          ? My::Test::Msg->try_from_packet( $msg, $ip )
          : join( ' ', unpack( '(H2)*', $buffer ) );
    }

    my $call     = sprintf( "%s.test_recv%s", $self->{_name}, describe( $named{args} ) );
    my $got      = describe( { msg => $msg } );
    my $expected = describe( $named{expect} );

    context_do {
        my $ctx = shift;

        $ctx->ok( $got eq $expected, sprintf( "%s -> %s", $call, $expected ), [ sprintf( "got: %s", $got ), ] );
    };

    return;

} ## end sub test_recv

sub test_send {
    state $top = validation_for(
        name          => 'test_send.top',
        return_object => 1,
        params        => {
            args   => { type => HashRef },
            expect => { type => Dict [] },
        },
    );

    state $args_v = validation_for(
        name          => 'test_send.expect',
        return_object => 1,
        params        => {
            msg => { type => $Msg },
        },
    );

    my ( $self, %named ) = @_;
    my $args = do {
        my $t = $top->( %named );
        $args_v->( %{ $t->args } );
    };

    my $msg;
    if ( IO::Select->new( $self->{_sock} )->can_write ) {
        my $resp = $args->{msg}->to_query->mk_packet( $args->{msg}{qid} );
        my $peer = $args->{peer};
        $self->{_sock}->send( $resp, 0, $peer );
    }

    my $call     = sprintf( "%s.test_send%s", $self->{_name}, describe( $named{args} ) );
    my $got      = describe( {} );
    my $expected = describe( {} );

    context_do {
        my $ctx = shift;

        $ctx->ok( $got eq $expected, sprintf( "%s -> %s", $call, $expected ), [ sprintf( "got: %s", $got ), ] );
    };

    return;

} ## end sub test_send

1;
