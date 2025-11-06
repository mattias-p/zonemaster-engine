package My::Test::TokenAllocator;
use v5.26;
use warnings;

use Carp     qw( confess );
use Exporter qw( import );
use Readonly;
use Test2::API    qw( context_do run_subtest );
use Type::Utils   qw( as declare where );
use Types::Common qw( ArrayRef CodeRef PositiveOrZeroInt );

our @EXPORT_OK = qw(
  $Token
  test_consumes_tokens
  alloc_mock_token
);

Readonly our $Token => declare as PositiveOrZeroInt, where { $_ <= 65535 };

our $mock_tokens;

sub test_consumes_tokens {
    my ( $tokens, $callback ) = @_;
    ( ArrayRef [$Token] )->check( $tokens );
    CodeRef->check( $callback );
    my @old_tokens = ( $mock_tokens // [] )->@*;
    local $mock_tokens = [ @old_tokens, $tokens->@* ];
    my $name = sprintf( 'should consume injected tokens [%s]', join( ',', $tokens->@* ) );
    run_subtest $name => sub {
        context_do {
            my $ctx = shift;
            $callback->();
            my $injected_count  = scalar $tokens->@*;
            my $remaining_count = scalar $mock_tokens->@* - scalar @old_tokens;
            $ctx->ok( scalar $mock_tokens->@* == 0,
                sprintf( "consumed %s of %s injected tokens", $injected_count - $remaining_count, $injected_count ) );
        };
    };

    return;
} ## end sub test_consumes_tokens

sub alloc_mock_token {
    if ( !defined $mock_tokens ) {
        confess 'must be called within the context of test_consumes_tokens()';
    }

    my $token = shift $mock_tokens->@*;
    if ( !defined $token ) {
        confess 'unexpected token allocation';
    }

    return $token;
}

1;
