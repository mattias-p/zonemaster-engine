package Zonemaster::Engine::Async::OsError;
use v5.26;
use warnings;

use English;

use overload
  '0+'     => \&errno,
  '""'     => \&errstr,
  fallback => 1;

sub from_errno {
    my ( $class ) = @_;

    my $value = $ERRNO;    # copy
    my $obj   = \$value;

    return bless $obj, $class;
}

sub from_mnemonic {
    my ( $class, $mnemonic ) = @_;

    local $ERRNO = Errno->$mnemonic();
    return Zonemaster::Engine::Async::OsError->from_errno;
}

sub origin {
    return "os";
}

sub message {
    my ( $self ) = @_;

    return sprintf( '%s (%d)', $self->errstr, $self->errno );
}

sub errno {
    my ( $self ) = @_;

    return 0+ $$self;
}

sub errstr {
    my ( $self ) = @_;

    return '' . $$self;
}

1;
