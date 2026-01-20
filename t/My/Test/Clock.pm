package My::Test::Clock;
use v5.26;
use warnings;

use Carp       qw( confess );
use Exporter   qw( import );
use Test2::API qw( context_do run_subtest );

our @EXPORT_OK = qw(
  advance_time
  now_mono
  test_advances_time
);

our $now_mono_ms;

sub test_advances_time {
    my ( $expect_ms, $callback ) = @_;

    local $now_mono_ms;
    $now_mono_ms //= 0;

    my $start_mono_ms = $now_mono_ms;

    run_subtest 'scope' => sub {
        context_do {
            my $ctx = shift;
            $ctx->note( sprintf( 'time to advance in this scope: %s ms', $expect_ms ) );
            $callback->();
            my $actual_ms = $now_mono_ms - $start_mono_ms;
            $ctx->ok( $actual_ms == $expect_ms, sprintf( "advanced %s ms of expected %s ms", $actual_ms, $expect_ms ) );
        };
    };
}

sub now_mono {
    if ( !defined $now_mono_ms ) {
        confess 'must be called within the context of test_consumes_tokens()';
    }

    return $now_mono_ms;
}

sub advance_time {
    my ( $delta_ms ) = @_;

    if ( !defined $now_mono_ms ) {
        confess 'must be called within the context of test_consumes_tokens()';
    }

    $now_mono_ms += $delta_ms;

    return;
}

1;
