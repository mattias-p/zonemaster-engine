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
    Makefile.PL
    lib/Zonemaster/Engine/Constants.pm
    lib/Zonemaster/Engine/DNSName.pm
    lib/Zonemaster/Engine/Exception.pm
    lib/Zonemaster/Engine/Logger/Entry.pm
    lib/Zonemaster/Engine/Nameserver/Cache/LocalCache.pm
    lib/Zonemaster/Engine/Nameserver/Cache.pm
    lib/Zonemaster/Engine/Nameserver/Cache/RedisCache.pm
    lib/Zonemaster/Engine/Nameserver.pm
    lib/Zonemaster/Engine/Net/IP.pm
    lib/Zonemaster/Engine/Normalization.pm
    lib/Zonemaster/Engine/NSArray.pm
    lib/Zonemaster/Engine/Packet.pm
    lib/Zonemaster/Engine.pm
    lib/Zonemaster/Engine/Profile.pm
    lib/Zonemaster/Engine/Recursor.pm
    lib/Zonemaster/Engine/Test/Address.pm
    lib/Zonemaster/Engine/Test/Basic.pm
    lib/Zonemaster/Engine/Test/Connectivity.pm
    lib/Zonemaster/Engine/Test/Consistency.pm
    lib/Zonemaster/Engine/Test/Delegation.pm
    lib/Zonemaster/Engine/Test/DNSSEC.pm
    lib/Zonemaster/Engine/TestMethods.pm
    lib/Zonemaster/Engine/TestMethodsV2.pm
    lib/Zonemaster/Engine/Test/Nameserver.pm
    lib/Zonemaster/Engine/Test/Syntax.pm
    lib/Zonemaster/Engine/Test/Zone.pm
    lib/Zonemaster/Engine/Translator.pm
    lib/Zonemaster/Engine/Zone.pm
    t/00-load.t
    t/asn.t
    t/dnsname.t
    t/logger.t
    t/nameserver-axfr.t
    t/nameserver.t
    t/normalization.t
    t/old-bugs.t
    t/pod-coverage.t
    t/pod.t
    t/profiles.t
    t/recursor.t
    t/Test-address.t
    t/Test-basic02-A.t
    t/Test-basic02-B.t
    t/Test-basic.t
    t/Test-connectivity03.t
    t/Test-connectivity04.t
    t/Test-connectivity.t
    t/Test-consistency05-A.t
    t/Test-consistency05-E.t
    t/Test-consistency05-F.t
    t/Test-consistency05-G.t
    t/Test-consistency05-H.t
    t/Test-consistency05-I.t
    t/Test-consistency05-J.t
    t/Test-consistency05-K.t
    t/Test-consistency05-L.t
    t/Test-consistency06-A.t
    t/Test-consistency06-B.t
    t/Test-consistency06-C.t
    t/Test-consistency06-D.t
    t/Test-consistency.t
    t/Test-delegation01-A.t
    t/Test-delegation01-B.t
    t/Test-delegation01-C.t
    t/Test-delegation01-D.t
    t/Test-delegation01-E.t
    t/Test-delegation01-F.t
    t/Test-delegation01-G.t
    t/Test-delegation01-H.t
    t/Test-delegation01-I.t
    t/Test-delegation01-J.t
    t/Test-delegation01-K.t
    t/Test-delegation01-L.t
    t/Test-delegation01-M.t
    t/Test-delegation02-A.t
    t/Test-delegation02-B.t
    t/Test-delegation02-C.t
    t/Test-delegation02-D.t
    t/Test-delegation03-A.t
    t/Test-delegation03-B.t
    t/Test-delegation03-C.t
    t/Test-delegation.t
    t/Test-dnssec03.t
    t/Test-dnssec05-A.t
    t/Test-dnssec05-B.t
    t/Test-dnssec05-C.t
    t/Test-dnssec05-D.t
    t/Test-dnssec05-E.t
    t/Test-dnssec05-F.t
    t/Test-dnssec05-G.t
    t/Test-dnssec05-H.t
    t/Test-dnssec05-I.t
    t/Test-dnssec05-J.t
    t/Test-dnssec16.t
    t/Test-dnssec-more.t
    t/Test-dnssec.t
    t/Test-nameserver01-A.t
    t/Test-nameserver01-B.t
    t/Test-nameserver01-C.t
    t/Test-nameserver01-D.t
    t/Test-nameserver15.t
    t/Test-nameserver.t
    t/Test-syntax06-A.t
    t/Test-syntax06-B.t
    t/Test-syntax06-C.t
    t/Test-syntax06-D.t
    t/Test-syntax06-E.t
    t/Test-syntax06-F.t
    t/Test-syntax06-G.t
    t/Test-syntax06-I.t
    t/Test-syntax06-J.t
    t/Test-syntax06-K.t
    t/Test-syntax06-L.t
    t/Test-syntax.t
    t/TestUtil.pm
    t/Test-zone01-A.t
    t/Test-zone01-B.t
    t/Test-zone09-1.t
    t/Test-zone09.t
    t/Test-zone.t
    t/translator.t
    t/undelegated.t
    t/util.t
    t/zonemaster.t
    t/zone.t
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
