package Mock::Scripted;
use v5.26;
use warnings;

use Carp qw( confess );
use Data::Dumper;
use Test::Builder;
use Test::Deep::NoTest qw( eq_deeply );

my $TB = Test::Builder->new;

=pod

=encoding utf-8

=head1 NAME

Mock::Scripted - Script exact method-call sequences with argument matching and controlled side effects

=head1 DESCRIPTION

Mock::Scripted is a minimal, scripted mock.
You predeclare an script: an sequence of method calls with effects and return values.
As the system under test makes the expected calls in the expected order, the effects and
return values are produced.
Each matching call is reported as a success to L<Test::Builder>.
As soon as the system under test goes off script, this is reported as a failure to
L<Test::Builder>, and execution aborts with L<confess|Carp/confess>.

Mock::Scripted is intended for testing sharp edge cases on a single collaborator. The
tradeoffs are brittleness when call order is non-deterministic and extra maintenance when
refactors change sequencing.

=head1 INTERFACE

=head2 new

  my $mock = Mock::Scripted->new;

Create an empty script.

=cut

sub new {
    my ( $class ) = @_;

    my $obj = [];

    return bless $obj, $class;
}

=head2 expect_call

  $mock->expect_call(\%expectation) -> $mock

Append one expectation to the script. See L</Expectation hash>.
Unknown keys and type errors are rejected with L<confess|Carp/confess>.

=cut

sub expect_call {
    my ( $self, $expectation ) = @_;

    if ( ref $expectation ne 'HASH' ) {
        confess 'script expectation must be a hashref';
    }

    my @impl = grep { exists $expectation->{$_} } qw( do returns );
    if ( @impl != 1 ) {
        confess 'exactly one of the following fields must be specified: do, returns';
    }

    my %exp = $expectation->%*;
    my ( $name, $method, $args, $do, $returns ) = delete @exp{qw( name method args do returns )};
    if ( %exp ) {
        confess 'unrecognized expectation fields: ' . join( ' ', sort keys %exp );
    }

    if ( ref $name ne '' ) {
        confess 'name must be a scalar';
    }

    if ( !defined $method || ref $method ne '' ) {
        confess 'method must be a defined scalar';
    }

    if ( ref $args ne 'ARRAY' ) {
        confess 'args field must be an arrayref, got ' . ( ref( $args ) || 'a scalar' );
    }

    if ( $impl[0] eq 'do' && ref $do ne 'CODE' ) {
        confess 'do field must be a coderef, got ' . ( ref( $do ) || 'a scalar' );
    }

    push $self->@*, $expectation;

    return $self;
} ## end sub expect_call

=head2 reset

  $mock->reset;

Clear the script. No return value.

=cut

sub reset {
    my ( $self ) = @_;

    $self->@* = ();

    return;
}

=head2 verify_done

  $mock->verify_done($name?);

Emit an C<ok> via L<Test::Builder> asserting that the script is exhausted.
On failure it emits diagnostics for each leftover expectation.

=cut

sub verify_done {
    my ( $self, $name ) = @_;

    $name //= 'no more calls expected';

    $TB->ok( scalar( $self->@* ) == 0, $name );

    for my $expectation ( $self->@* ) {
        my ( $exp_method, $exp_args, $do ) = $expectation->@{qw( method args do )};
        my %exp = (
            method => $exp_method,
            args   => $exp_args,
        );
        $TB->diag( "leftover: " . ( $expectation->{name} // "call to '$exp_method'" ) );
        local $Data::Dumper::Purity   = 0;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Terse    = 1;
        $TB->diag( Dumper( \%exp ) );
    }

    return;
} ## end sub verify_done

=head2 is_exhausted

  my $ok = $mock->is_exhausted;

Returns a boolean indicating emptiness.

=cut

sub is_exhausted {
    my ( $self ) = @_;

    return !$self->@*;
}

=head2 Any other method name

  $mock->some_method(@args);

All other method names are handled by C<AUTOLOAD> (C<DESTROY> excluded).
Each call must match the next scripted expectation.
On mismatch or script exhaustion a failing test is emitted, a diagnostic dump of C<got> vs
C<expected> is printed, and the code L<confess|Carp/confess>es.

=cut

sub AUTOLOAD {
    my ( $self, @args ) = @_;
    our $AUTOLOAD;

    if ( $AUTOLOAD =~ /::DESTROY\z/ ) {
        return;
    }

    my $got_method = $AUTOLOAD =~ s/^.*:://r;
    my %got        = (
        method => $got_method,
        args   => \@args,
    );

    my $expectation = shift( $self->@* );
    if ( !$expectation ) {
        $TB->ok( 0, 'no more calls expected, got ' . $got_method );
        $TB->diag( Dumper( \%got ) );
        confess "unexpected call to '$got_method'";
    }

    my ( $name, $exp_method, $exp_args, $do, $returns ) = $expectation->@{qw( name method args do returns )};
    my %exp = (
        method => $exp_method,
        args   => $exp_args,
    );

    $name //= "call to '$exp_method' with expected args";

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    my $ok = eq_deeply( \%got, \%exp );

    $TB->ok( $ok, $name );
    if ( !$ok ) {
        local $Data::Dumper::Purity   = 0;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Terse    = 1;
        $TB->diag( Dumper( \%got, \%exp ) );
        confess "unexpected call to '$got_method'";
    }

    if ( $do ) {
        return $do->( @args );
    }
    else {
        return $returns;
    }
} ## end sub AUTOLOAD

1;

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

=head1 SEE ALSO

L<Test::More>, L<Test::Builder>, L<Test::Deep>, L<Carp>.

=cut
