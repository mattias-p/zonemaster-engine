package Zonemaster::Engine::Async::IoError;
use v5.26;
use warnings;

use Role::Tiny::With qw( with );

with 'Zonemaster::Engine::Async::ErrorRole';

sub new {
    my ( $class, $errno ) = @_;

    my $obj = { _errno => $errno };

    return bless $obj, $class;
}

sub msg {
    my ( $self ) = @_;

    return sprintf( '%s (%s)', $self->strerror, join( '/', $self->mnemonic, $self->errno ) );
}

sub strerror {
    my ( $self ) = @_;

    return '' . $self->{_errno};
}

sub errno {
    my ( $self ) = @_;

    return +$self->{_errno};
}

sub mnemonic {
    my ( $self ) = @_;

    local $! = $self->{_errno};

    return sort grep { $!{$_} } keys %!;
}

1;
