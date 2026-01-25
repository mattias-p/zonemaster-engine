package Zonemaster::Engine::Async::Error;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Exporter qw( import );
use Readonly;
use Zonemaster::Engine::Async::LdnsError;
use Zonemaster::Engine::Async::OsError;

Readonly our @EXPORT_OK => qw(
  new_os_error_from_errno
  new_ldns_error
);

sub new_os_error_from_errno {
    return Zonemaster::Engine::Async::OsError->from_errno;
}

sub new_ldns_error {
    return Zonemaster::Engine::Async::LdnsError->new;
}

use overload
  '""'   => 'message',
  'bool' => sub { 0 };    # errors are false in boolean context

sub new {
    my ( $class, %args ) = @_;

    my ( $code, $kind, $message ) = delete @args{qw( code kind message )};

    croak 'unrecognized args: ' . join( ', ', sort keys %args )
      if %args;
    croak 'invalid code'
      if $code !~ $CODE_RE;
    croak 'invalid kind'
      if $kind !~ $KIND_RE;

    my $obj = {
        _code    => $code,
        _kind    => $kind,
        _message => $message,
    };

    return bless $obj, $class;
} ## end sub new

sub from_failure {
    my ( $class, $kind, $code, $op ) = @_;

    my $mnemonics = join( '|', $code, _errno_mnemonics( $code ) );
    my $message   = sprintf( "%s failed: %s (%s)", $op, $code, $mnemonics );

    return $class->new( $code, $kind, $message );
}

sub from_eof {
    my ( $class, $kind, $op ) = @_;

    my $message = "$op hit end of file (EOF)";

    return $class->new( 'EOF', 'connection', $message );
}

sub from_timeout {
    my ( $class, $kind, $op ) = @_;

    my $message = "$op timed out (TIMEOUT)";

    return $class->new( 'TIMEOUT', $kind, $message );
}

sub code    { $_[0]{code} }
sub kind    { $_[0]{kind} }
sub message { $_[0]{message} }

sub _errno_mnemonics {
    my ( $errno ) = @_;

    if ( 0+ $errno == 0 ) {
        return;
    }

    local $ERRNO = $errno;

    return sort grep { $!{$_} } keys %!;
}

1;
