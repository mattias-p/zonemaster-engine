package Zonemaster::Engine::Async::ErrorRole;
use v5.26;
use warnings;

use Role::Tiny qw( requires );

requires qw(
  msg
  short
);

1;
