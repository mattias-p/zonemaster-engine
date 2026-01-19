package Zonemaster::Engine::Async::Client;
use v5.26;
use warnings;

use Scalar::Util qw( refaddr );

use Zonemaster::Engine::Async qw( mk_udp_socket );
use Zonemaster::Engine::Async::UDPAdapter;

sub new {
    my ( $class, %args ) = @_;

    my (    #
        $udp_socket_factory,
      )
      = delete @args{
        qw(
          udp_socket_factory
        )
      };
    if ( %args ) {
        croak 'unrecognized args: ' . join( ', ', sort keys %args );
    }

    $udp_socket_factory //= &mk_udp_socket;

    my $obj = {
        udp_adapter        => undef,
        udp_socket_factory => $udp_socket_factory,
        adapters           => {},                    # hash from socket refaddr to adapter
        queries            => {},                    # hash from qid to id
    };

    return bless $obj, $class;
} ## end sub new

sub enqueue_udp {
    my ( $self, $id, $query ) = @_;

    if ( !defined $self->{udp_adapter} ) {
        my $socket = $self->{udp_socket_factory};
        my $adapter => Zonemaster::Engine::Async::UDPAdapter->new( $socket );
        $self->{adapters}{ refaddr( $socket ) } = $adapter;
        $self->{udp_adapter} = $adapter;
    }

    my $qid = $self->_alloc_qid( $id );
    $self->{udp_adapter}->enqueue( $query->mk_wire( $qid ) );

    return;
}

sub once {
    my ( $self ) = @_;

    my %responses;

    my @awaiting_read  = grep { $_->awaiting_read } values $self->{adapters};
    my @awaiting_write = grep { $_->awaiting_write } values $self->{adapters};

    if ( my ( $ready_read, $ready_write ) = IO::Select->select( \@awaiting_read, \@awaiting_write, [] ) ) {
        for my $socket ( $ready_read->@* ) {
            my $adapter   = $self->{adapters}{ refaddr( $socket ) };
            my @responses = $adapter->on_ready_read;
            for ( my $i = 0 ; $i < $#responses ; $i += 2 ) {
                my ( $server_ip, $response ) = ( $responses[$i], $responses[ $i + 1 ] );
                my $qid = unpack( 'n', $response );
                my $id  = delete $self->{queries}{$qid};
                $responses{$id} = $response;
            }
        }

        for my $socket ( $ready_write->@* ) {
            my $adapter = $self->{adapters}{ refaddr( $socket ) };
            $adapter->on_ready_write;
        }
    }

    return %responses;
} ## end sub once

sub _alloc_qid {
    my ( $self, $id ) = @_;

    if ( keys $self->{queries}->%* >= 65536 ) {
        croak 'qid exhaustion';
    }

    # Linearly walk the range of qids with a random step size from a random starting point
    # until an available qid is found. An uninterrupted walk is guaranteed to visit every
    # other qid before returning to the starting point because no odd numbers have any
    # common divisor with the range size.
    my $qid  = int( rand( 0x10000 ) );
    my $step = int( rand( 0x10000 ) ) | 0x0001;
    while ( exists $self->{queries}{$qid} ) {
        $qid = ( $qid + $step ) & 0xffff;
    }

    $self->{queries}{$qid} = $id;

    return $qid;
} ## end sub _alloc_qid

1;
