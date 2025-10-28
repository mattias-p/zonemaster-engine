package Mock::Scripted;
use v5.26;
use warnings;

use Exporter           qw( import );
use Test::Deep         qw( eq_deeply );
use Test2::API         qw( context_do );
use Test2::Tools::Mock qw( mock );
use TestUtil           qw( friendly_dump );

our @EXPORT_OK = qw( new_scripted_mock );

=pod

=encoding utf-8

=head1 NAME

Mock::Scripted - Script exact method-call sequences with argument matching and side-effect hooks

=head1 DESCRIPTION

Mock::Scripted is a minimal, scripted mock.
You predeclare a script: a sequence of method calls with effects and return values.
As the system under test makes the expected calls in the expected order, the effects and
return values are produced.
As soon as the system under test goes off script, this is reported as a failure and
execution aborts with an exception.

Mock::Scripted is intended for testing sharp edge cases on a single collaborator. The
tradeoffs are brittleness when call order is non-deterministic and extra maintenance when
refactors change sequencing.

=cut

sub _call_string {
    my ( $method, $args ) = @_;

    my @friendly_args = map { "  " . friendly_dump( $_ ) . ",\n" } $args->@*;

    return sprintf "%s(\n%s)", $method, join( '', @friendly_args );
}

sub _process_call {
    my $mock   = shift;
    my $method = shift;
    my @args   = @_;

    my $step;

    context_do {
        my $ctx = shift;

        if ( $mock->{_i} >= $mock->{_steps}->@* ) {
            $ctx->ok( 0, sprintf( "step %d: no more calls expected, got %s", $mock->{_i} + 1, $method ) );
            $ctx->diag( friendly_dump( \@args ) );
            $ctx->croak( "return value cannot be determined" );
        }

        $step = $mock->{_steps}[ $mock->{_i} ];

        my $ok   = $method eq $step->{method} && eq_deeply( \@args, $step->{args} );
        my $name = $step->{name} // sprintf( "call to '%s'", $step->{method} );

        $ctx->ok( $ok, sprintf( "step %d: %s per expectation at %s", $mock->{_i} + 1, $name, $step->{origin} ) );
        if ( !$ok ) {
            $ctx->diag(
                sprintf "expected %s, got %s",
                _call_string( $step->{method}, $step->{args} ),
                _call_string( $method,         \@args ),
            );
            $ctx->croak( "return value cannot be determined" );
        }

        $mock->{_i} += 1;
    };

    return $step->{do}
      ? $step->{do}->( @_ )
      : $step->{returns};
} ## end sub _process_call

sub new_scripted_mock {
    my ( @allowed_methods ) = @_;

    my %allowed = map { $_ => 1 } @allowed_methods;

    my $mock = mock {} => (
        add => [
            map {
                my $method = $_;

                $method => sub {
                    splice @_, 1, 0, $method;
                    _process_call( @_ );
                }
            } keys %allowed
        ]
    );
    $mock->{_steps} = [];
    $mock->{_i}     = 0;

    my $controller = bless {
        _mock    => $mock,
        _allowed => \%allowed,
      },
      'Mock::Scripted::Ctl';

    return ( $controller, $mock );
} ## end sub new_scripted_mock

=head1 Expectation hash

Each expectation is a hashref with strict keys:

=over 4

=item * C<name>  (optional)

Scalar. Test name passed to C<ok>. Default: a generated description.

=item * C<method>  (required)

Defined scalar. The method name expected.

=item * C<args>  (required)

Arrayref. The exact argument list. You may include L<Test::Deep> matchers
(e.g. C<re(...)>, C<num(...)>, C<array_each(...)>) to relax matching.

=item * Exactly one of:

  returns => $any         # fixed return value
  do      => sub { ... }  # coderef implementing behavior

=back

N.b., C<do> may modify C<$!> to simulate syscalls.

=cut

package Mock::Scripted::Ctl;
use v5.26;
use warnings;

use Carp       qw( confess );
use Test2::API qw( context_do );
use TestUtil   qw( friendly_dump );

sub _validate_step {
    my ( $self, $step ) = @_;

    if ( ref( $step ) ne 'HASH' ) {
        confess 'step must be a hashref';
    }

    my @missing = grep { !exists $step->{$_} } qw( method args );
    if ( @missing ) {
        confess 'missing step fields: ' . join( ', ', @missing );
    }

    my @impl = grep { exists $step->{$_} } qw( do returns );
    if ( @impl != 1 ) {
        confess 'exactly one of the following fields must be specified: do, returns';
    }

    my %exp = $step->%*;
    my ( $name, $method, $args, $do, $returns ) = delete @exp{qw( name method args do returns )};
    if ( %exp ) {
        confess 'unrecognized step fields: ' . join( ' ', sort keys %exp );
    }

    if ( ref( $name ) ne '' ) {
        confess 'name field must be a scalar';
    }

    confess 'method field must specify an allowed method'
      if !exists $self->{_allowed}{$method};

    if ( ref( $args ) ne 'ARRAY' ) {
        confess 'args field must be an arrayref, got ' . ( ref( $args ) || 'a scalar' );
    }

    if ( exists $step->{do} && ref( $do ) ne 'CODE' ) {
        confess 'do field must be a coderef';
    }

    return;
} ## end sub _validate_step

sub expect {
    my ( $self, $step ) = @_;

    $self->_validate_step( $step );

    push $self->{_mock}{_steps}->@*, {
        $step->%*,
        origin => do {
            my ( undef, $file, $line ) = caller;
            "$file:$line";
        },
    };

    return;
}

sub remaining {
    my ( $self ) = @_;

    return [ $self->{_mock}{_steps}->@[ $self->{_mock}{_i} .. $self->{_mock}{_steps}->$#* ] ];
}

sub done_ok {
    my ( $self, $name ) = @_;

    context_do {
        my $ctx = shift;

        my $remaining = $self->remaining;

        my $message = sprintf 'before step %d: %s', $self->{_mock}{_i} + 1, $name // 'all expected calls were made';
        $ctx->ok( !$remaining->@*, $message );
        if ( $remaining->@* ) {
            $ctx->diag( "unfulfilled expectations:" . friendly_dump( $remaining ) );
        }
    };

    return;
}

sub is_exhausted {
    my ( $self ) = @_;

    return $self->{_mock}{_i} >= $self->{_mock}{_steps}->@*;
}

sub DESTROY {
    my ( $self ) = @_;

    if ( !$self->is_exhausted ) {
        warn "Mock::Scripted destroyed with unfulfilled expectations:\n" . friendly_dump( $self->remaining );
    }

    return;
}

1;
