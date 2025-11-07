package My::Test::Msg;
use v5.26;
use warnings;

use Exporter                   qw( import );
use My::Test::TokenAllocator   qw( $Uint16 );
use Params::ValidationCompiler qw( validation_for );
use Readonly;
use Scalar::Util  qw( blessed );
use Types::Common qw( Bool Enum InstanceOf NonEmptySimpleStr );
use Zonemaster::Engine::Async::Query;

Readonly our $Msg => InstanceOf ['My::Test::Msg'];

our @EXPORT_OK = qw(
  $Msg
  msg
);

sub msg {
    return My::Test::Msg->new( @_ );
}

use Data::Dumper;

sub new {
    my ( $class, %args ) = @_;

    state $check = validation_for(
        name   => 'msg',
        params => {
            peer  => { type => NonEmptySimpleStr },
            qname => { type => NonEmptySimpleStr },
            qtype => { type => Enum [qw( SOA )] },
            qid   => { type => $Uint16, default => 0 },
            qr    => { type => Bool,    default => 0 },
            tc    => { type => Bool,    default => 0 },
        },
    );

    %args = $check->( %args );

    $args{qr} = $args{qr} ? 1 : 0;
    $args{tc} = $args{tc} ? 1 : 0;

    my $obj = \%args;

    return bless $obj, $class;
} ## end sub new

sub try_from_packet {
    my ( $class, $packet, $peer ) = @_;

    if (   !blessed $packet
        || !$packet->isa( 'Zonemaster::LDNS::Packet' )
        || $packet->question != 1
        || $packet->answer != 0
        || $packet->authority != 0
        || $packet->additional != 0 )
    {
        return $packet;
    }

    my ( $question ) = $packet->question;

    return $class->new(
        peer  => $peer,
        qname => $question->name,
        qtype => $question->type,
        qid   => $packet->id,
        qr    => $packet->qr,
        tc    => $packet->tc,
    );
} ## end sub try_from_packet

sub to_query {
    my ( $self ) = @_;
    return Zonemaster::Engine::Async::Query->new(
        qname  => $self->{qname},
        qtype  => $self->{qtype},
        server => $self->{peer},
    );
}

sub short {
    my ( $self ) = @_;

    my %default = (
        qid => 0,
        qr  => 0,
        tc  => 0,
    );

    my %remaining = $self->%*;

    my @args;
    push @args, sprintf( "peer => '%s'",  delete $remaining{peer} );
    push @args, sprintf( "qname => '%s'", delete $remaining{qname} );
    push @args, sprintf( "qtype => '%s'", delete $remaining{qtype} );

    for my $key ( sort keys %remaining ) {
        my $value = $remaining{$key};
        if ( $value ne $default{$key} ) {
            push @args, sprintf( "%s => '%s'", $key, $value );
        }
    }

    return sprintf( 'msg(%s)', join( ', ', @args ) );
} ## end sub short

1;
