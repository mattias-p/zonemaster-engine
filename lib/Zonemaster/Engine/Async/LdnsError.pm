package Zonemaster::Engine::Async::LdnsError;
use v5.26;
use warnings;

use English;
use Zonemaster::LDNS::Status;

use overload
  '0+'     => \&errno,
  '""'     => \&errorstr,
  fallback => 1;

sub new {
    my ( $class, $status ) = @_;

    my $obj = \$status;

    return bless $obj, $class;
}

sub origin {
    return "ldns";
}

sub message {
    my ( $self ) = @_;

    return $self->status->message;
}

sub status {
    my ( $self ) = @_;

    return $$self;
}

1;
