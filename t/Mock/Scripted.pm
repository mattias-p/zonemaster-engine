package Mock::Scripted;
use v5.26;
use warnings;

use Carp qw( confess );
use Data::Dumper;
use Test::Builder;
use Test::Deep::NoTest qw( eq_deeply );

my $TB = Test::Builder->new;

sub new {
    my ( $class ) = @_;

    my $obj = [];

    return bless $obj, $class;
}

sub expect_call {
    my ( $self, $expectation ) = @_;

    _validate_expectation( $expectation );

    push $self->@*, $expectation;

    return $self;
}

sub reset {
    my ( $self ) = @_;

    $self->@* = ();
}

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

    return !$self->@*;
} ## end sub verify_done

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

sub _validate_expectation {
    my ( $expectation ) = @_;

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

    return;
} ## end sub _validate_expectation

1;
