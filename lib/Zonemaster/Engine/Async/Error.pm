package Zonemaster::Engine::Async::Error;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Exporter qw( import );
use Readonly;

Readonly our @EXPORT_OK => qw(
  $DESTINATION_KIND
  $FATAL_KIND
  $MESSAGE_KIND
  $SOCKET_KIND
  $TRANSIENT_KIND
  $EOF_CODE
  $TIMEOUT_CODE
);

=head2 CONSTANTS

=over 4

=item $DESTINATION_KIND

Requests to the same destination are expected to fail.

=item $FATAL_KIND

Requests from the same process are expected to fail.

=item $MESSAGE_KIND

Requests using the same message are expected to fail.

=item $SOCKET_KIND

Requests using the same local socket are expected to fail.

=item $TRANSIENT_KIND

A repeated request has a reasonable chance of succeeding.

=cut

Readonly our $EOF_CODE     => 'EOF';
Readonly our $TIMEOUT_CODE => 'TIMEOUT';

Readonly our $DESTINATION_KIND => 'destination';    # requests to the same destination are expected to fail
Readonly our $FATAL_KIND       => 'fatal';          # requests from the same process are expected to fail
Readonly our $MESSAGE_KIND     => 'message';        # requests using the same message are expected to fail
Readonly our $SOCKET_KIND      => 'socket';         # requests using the same local socket are expected to fail
Readonly our $TRANSIENT_KIND   => 'transient';      # a repeated request has a good chance of succeeding

Readonly our $KIND_RE => qr{^(?:$DESTINATION_KIND|$FATAL_KIND|$MESSAGE_KIND|$SOCKET_KIND|$TRANSIENT_KIND)$};
Readonly our $CODE_RE => qr{^(?:[1-9][0-9]+|$EOF_CODE|$TIMEOUT_CODE)$};

use overload
  '""'   => 'message',
  'bool' => sub { 0 };                              # errors are false in boolean context

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
