package Mock::Behavior;
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

sub append_script {
    my ( $self, @script ) = @_;

    for my $i ( 0 .. $#script ) {
        eval { _validate_expected( $script[$i] ) };
        if ( $@ ) {
            die "position $i: $@";    # rethrow
        }
    }

    push $self->@*, @script;

    return $self;
}

sub ok_done {
    my ( $self, $name ) = @_;

    $name //= 'no more calls expected';

    $TB->ok( scalar( $self->@* ) == 0, $name );

    for my $expected ( $self->@* ) {
        my ( $exp_method, $exp_args, $code ) = $expected->@{qw( method args code )};
        my %exp = (
            method => $exp_method,
            args   => $exp_args,
        );
        $TB->diag( "leftover: " . ( $expected->{name} // "call to '$exp_method'" ) );
        local $Data::Dumper::Purity   = 0;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Terse    = 1;
        $TB->diag( Dumper( \%exp ) );
    }

    return !$self->@*;
} ## end sub ok_done

sub AUTOLOAD {
    my ( $self, @args ) = @_;
    our $AUTOLOAD;

    if ( $AUTOLOAD =~ /::DESTROY\z/ ) {
        return;
    }

    my $expected = shift( $self->@* ) // {};
    my ( $name, $exp_method, $exp_args, $code ) = $expected->@{qw( name method args code )};
    $exp_method //= '<none>';
    $name       //= "call to '$exp_method' with expected args";

    my $got_method = $AUTOLOAD =~ s/^.*:://r;

    my @got = (
        method => $got_method,
        args   => \@args,
    );
    my @exp =
      $expected
      ? (
        method => $exp_method,
        args   => $exp_args,
      )
      : ();

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    my $ok = eq_deeply( \@got, \@exp );

    $TB->ok( $ok, $name );
    if ( !$ok ) {
        local $Data::Dumper::Purity   = 0;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Terse    = 1;
        $TB->diag( Dumper( \@got, \@exp ) );
        confess "unexpected call to '$got_method'";
    }

    return $code->( @args );
} ## end sub AUTOLOAD

sub _validate_expected {
    my ( $expected ) = @_;

    if ( ref $expected ne 'HASH' ) {
        confess 'script expectation must be a hashref';
    }
    my %exp = $expected->%*;
    my ( $name, $method, $args, $code ) = delete @exp{qw( name method args code )};
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

    if ( ref $code ne 'CODE' ) {
        confess 'code field must be a coderef, got ' . ( ref( $args ) || 'a scalar' );
    }

    return;
} ## end sub _validate_expected

1;
