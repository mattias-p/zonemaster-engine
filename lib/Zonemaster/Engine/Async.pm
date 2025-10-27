package Zonemaster::Engine::Async;
use v5.26;
use warnings;

use Carp     qw( croak );
use Exporter qw( import );
use IO::Socket;
use Socket qw( AF_INET AF_INET6 );

our @EXPORT_OK = qw(
  friendly_dump
  is_with_context
  pack_sockaddr
  unified_dumper_diff
  unpack_sockaddr
);

sub mk_udp_socket {
    my ( $port ) = @_;

    my $socket = IO::Socket::INET->new(
        Blocking => 0,
        Domain   => IO::Socket::AF_INET,
        PeerPort => $port,
        Type     => IO::Socket::SOCK_DGRAM,
    ) or croak( "socket: $@" );

    return $socket;
}

=head2 unpack_sockaddr

TODO: document the exact format of the returned IP address

=cut

sub unpack_sockaddr {
    my ( $sockaddr ) = @_;

    my $family = Socket::sockaddr_family( $sockaddr );

    my ( $port, $addr ) =
      $family == AF_INET6
      ? Socket::sockaddr_in6( $sockaddr )
      : Socket::sockaddr_in( $sockaddr );

    return ( $port, Socket::inet_ntop( $family, $addr ) );
}

sub pack_sockaddr {
    my ( $ip, $port ) = @_;

    if ( my $bin = Socket::inet_pton( AF_INET6, $ip ) ) {
        return Socket::pack_sockaddr_in6( $port, $bin );
    }

    if ( my $bin = Socket::inet_pton( AF_INET, $ip ) ) {
        return Socket::pack_sockaddr_in( $port, $bin );
    }

    croak "invalid IP";
}

1;
