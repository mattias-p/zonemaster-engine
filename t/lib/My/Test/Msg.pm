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

sub new {
    my ( $class, %args ) = @_;

    state $check = validation_for(
        name   => 'msg',
        params => {
            qname => { type => NonEmptySimpleStr },
            qtype => { type => Enum [qw( SOA )] },
            qid   => { type => $Uint16, default => 0 },
            qr    => { type => Bool,    default => 0 },
        },
    );

    %args = $check->( %args );

    my $obj = \%args;

    return bless $obj, $class;
}

sub try_from_packet {
    my ( $class, $packet ) = @_;

    if (   !blessed $packet
        || !$packet->isa( 'Zonemaster::Engine::Packet' )
        || $packet->question != 1
        || $packet->answer != 0
        || $packet->authority != 0
        || $packet->additional != 0 )
    {
        return $packet;
    }

    my ( $question ) = $packet->question;

    return $class->new(
        qname => $question->name,
        qtype => $question->type,
        qr    => $packet->qr,
        qid   => $packet->id,
    );
} ## end sub try_from_packet

sub to_query {
    my ( $self ) = @_;
    return Zonemaster::Engine::Async::Query->new(
        qname  => $self->{qname},
        qtype  => $self->{qtype},
        server => '10.10.10.53'
    );
}

sub short {
    my ( $self ) = @_;

    my @args;

    push @args, sprintf( "qname => '%s'", $self->{qname} );
    push @args, sprintf( "qtype => '%s'", $self->{qtype} );
    if ( $self->{qid} != 0 ) {
        push @args, sprintf( "qid => '%s'", $self->{qid} );
    }
    if ( $self->{qr} != 0 ) {
        push @args, sprintf( "qr => '%s'", $self->{qr} );
    }

    return sprintf( 'msg(%s)', join( ', ', @args ) );
}

1;
