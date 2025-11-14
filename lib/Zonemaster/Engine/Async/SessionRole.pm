package Zonemaster::Engine::Async::SessionRole;
use v5.26;
use warnings;

use Role::Tiny qw( requires );

requires qw(
  add_request
  add_timeout
  step
);

1;
