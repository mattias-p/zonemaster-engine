use v5.16;
use warnings FATAL => 'all';
use Test::More;

BEGIN {
    use_ok( 'Zonemaster::Engine' )            || say "Bail out!";
    use_ok( 'Zonemaster::Engine::Profile' )   || say "Bail out!";
    use_ok( 'Zonemaster::Engine::Constants' ) || say "Bail out!";
}

diag( "Testing Zonemaster Engine $Zonemaster::Engine::VERSION, Perl $], $^X" );

done_testing;
