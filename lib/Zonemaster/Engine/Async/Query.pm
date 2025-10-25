package Zonemaster::Engine::Async::Query;
use v5.26;
use warnings;

use Carp       qw( croak );
use List::Util qw( any );

use Zonemaster::Engine::Constants qw( :misc );
use Zonemaster::LDNS::Packet;

sub new {
    my ( $class, %args ) = @_;

    my @missing = grep { !defined $args{$_} } qw( server qname qtype );

    if ( @missing ) {
        croak 'missing required arguments: ' . join( ', ', @missing );
    }

    my (    #
        $server,
        $qname,
        $qtype,
        $qclass,
        $rd,
        $qr,
        $edns_version,
        $edns_udp_size,
        $edns_do,
        $edns_z,
        $edns_data,
      )
      = delete @args{
        qw(
          server
          qname
          qtype
          qclass
          rd
          qr
          edns_version
          edns_udp_size
          edns_do
          edns_z
          edns_data
        )
      };
    if ( %args ) {
        croak 'unrecognized args: ' . join( ', ', sort keys %args );
    }

    if ( any { defined $_ } $edns_version, $edns_udp_size, $edns_do, $edns_z, $edns_data ) {
        $edns_version //= 0;
        $edns_do      //= 0;
        $edns_z       //= 0;
        $edns_data    //= '';
        $edns_udp_size //=
            $edns_do
          ? $EDNS_UDP_PAYLOAD_DNSSEC_DEFAULT
          : $EDNS_UDP_PAYLOAD_DEFAULT;
    }

    $qclass //= 'IN';
    $rd     //= 0;
    $qr     //= 0;

    $qclass = uc( $qclass );
    $qtype  = uc( $qtype );

    my $obj = {
        server        => $server,
        qname         => $qname,
        qtype         => $qtype,
        qclass        => $qclass,
        rd            => $rd,
        qr            => $qr,
        edns_version  => $edns_version,
        edns_udp_size => $edns_udp_size,
        edns_do       => $edns_do,
        edns_z        => $edns_z,
        edns_data     => $edns_data,
    };

    return bless $obj, $class;
} ## end sub new

sub server {
    my ( $self ) = @_;

    return $self->{server};
}

sub mk_packet {
    my ( $self, $qid ) = @_;

    my $packet = Zonemaster::LDNS::Packet->new( $self->{qname}, $self->{qtype}, $self->{qclass} );

    $packet->qr( $self->{qr} );
    $packet->id( $qid );
    $packet->rd( $self->{rd} );

    if ( defined $self->{edns_version} ) {
        $packet->set_edns_present();
        $packet->do( $self->{edns_do} );
        $packet->edns_size( $self->{edns_udpsize} );
        $packet->edns_version( $self->{edns_version} );
        $packet->edns_z( $self->{edns_z} );
        if ( $self->{edns_data} ) {
            $packet->edns_data( $self->{edns_data} );
        }
    }

    return $packet;
} ## end sub mk_packet

sub mk_wire {
    my ( $self, $qid ) = @_;

    return $self->mk_packet( $qid )->data;
}

1;
