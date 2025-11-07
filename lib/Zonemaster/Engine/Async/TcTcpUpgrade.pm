package Zonemaster::Engine::Async::TcTcpUpgrade;
use v5.26;
use warnings;

use Role::Tiny::With qw( with );

with 'Zonemaster::Engine::Async::SessionRole';

sub new {
    my ( $class, $inner ) = @_;

    my $obj = {
        _inner    => $inner,
        _udp      => {},
        _upgraded => {},
    };

    return bless $obj, $class;
}

sub add_timeout {
    my ( $self, $duration ) = @_;

    return $self->{_inner}->add_timeout( $duration );
}

sub add_request {
    my ( $self, $query ) = @_;

    my $token = $self->{_inner}->add_request( $query );

    if ( $query->proto eq 'udp' ) {
        $self->{_udp}{$token} = $query;
    }

    return $token;
}

sub tick {
    my ( $self ) = @_;

    my @events = $self->{_inner}->tick();

    my @results;
    while ( @events ) {
        my ( $token, $event ) = splice @events, 0, 2;

        if ( my $orig_query = delete $self->{_udp}{$token} ) {
            my $upgraded = $self->{_inner}->add_request( $orig_query->with( proto => 'tcp' ) );
            $self->{_upgraded}{$upgraded} = $token;
        }
        elsif ( my $orig_token = delete $self->{_upgraded}{$token} ) {
            push @results, ( $orig_token, $event );
        }
        else {
            push @results, ( $token, $event );
        }
    }

    return @results;
} ## end sub tick

1;
