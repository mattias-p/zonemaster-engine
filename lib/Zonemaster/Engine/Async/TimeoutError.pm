package Zonemaster::Engine::Async::TimeoutError;
use v5.26;
use warnings;

use Role::Tiny::With qw( with );

with 'Zonemaster::Engine::Async::ErrorRole';

sub new {
    my ( $class ) = @_;

    my $obj = {};

    return bless $obj, $class;
}

sub msg {
    my ( $self ) = @_;

    return 'Timeout';
}

sub short {
    return 'timeout()';
}

1;
