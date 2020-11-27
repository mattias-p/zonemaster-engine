#!perl
use v5.14.2;
use strict;
use warnings;
use utf8;
use Test::More tests => 1;

use File::Basename qw( dirname );

chdir dirname( dirname( __FILE__ ) ) or BAIL_OUT( "chdir: $!" );
chdir 'share' or BAIL_OUT( "chdir: $!" );

my $makebin = 'make';
if ($^O eq "freebsd") {
    # This unit test requires GNU Make
    $makebin = 'gmake';
};

sub make {
    my @make_args = @_;

    my $command = join( ' ', $makebin, '--silent', '--no-print-directory', @make_args );
    my $output = `$command`;

    if ( $? == -1 ) {
        BAIL_OUT( "failed to execute: $!" );
    }
    elsif ( $? & 127 ) {
        BAIL_OUT( "child died with signal %d, %s coredump\n", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without' );
    }

    return $output, $? >> 8;
}

subtest "no fuzzy marks" => sub {
    SKIP: {
        skip 'msgattrib not installed', 2
          if not `which msgattrib`;

        my ( $output, $status ) = make "show-fuzzy";
        is $status, 0,  $makebin . ' show-fuzzy exits with value 0';
        is $output, "", $makebin . ' show-fuzzy gives empty output';
    };
};
