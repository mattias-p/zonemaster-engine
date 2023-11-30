use strict;
use warnings;
use Test::More;

use File::Basename;
use Perl::Critic::Utils;
use Test::Perl::Critic;

# $AMBITIOUS_SEVERITY is the level of enforcement which we are aiming to bring
# all our sources to.
my $AMBITIOUS_SEVERITY = 5;

# %ASPIRING_FILES defines the set of files that we aspire to fix so they pass
# $AMBITIOUS_SEVERITY enforcement.
#
# Files should be removed from here as they pass $AMBITIOUS_SEVERITY
# enforcement.
#
# When this set is empty we should consider tightening $AMBITIOUS_SEVERITY to
# the next step and populate this set again with the files that don't meet the
# new standards.
my %ASPIRING_FILES = map { ( $_ => 1 ) } qw(
    t/normalization.t
    t/Test-basic.t
    t/Test-zone.t
    t/util.t
    t/zonemaster.t
);

my $rcfile = dirname( dirname( __FILE__ ) ) . "/.perlcriticrc";

Test::Perl::Critic->import( -profile => $rcfile, -severity => $AMBITIOUS_SEVERITY );
my @all_files = Perl::Critic::Utils::all_perl_files( qw( Makefile.PL lib t ) );
for my $file ( sort @all_files ) {
    if ( !exists $ASPIRING_FILES{$file} ) {
        critic_ok( $file, "Perl::Critic severity $AMBITIOUS_SEVERITY test for $file" );
    }
}

my $aspiring_severity = $AMBITIOUS_SEVERITY + 1;
if ( $aspiring_severity <= 5 ) {
    Test::Perl::Critic->import( -profile => $rcfile, -severity => $aspiring_severity );
    for my $file ( sort keys %ASPIRING_FILES ) {
        critic_ok( $file, "Perl::Critic severity $aspiring_severity test for $file" );
    }
}

done_testing;
