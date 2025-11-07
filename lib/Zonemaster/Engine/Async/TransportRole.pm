package Zonemaster::Engine::Async::TransportRole;
use v5.26;
use warnings;

use Carp qw( croak );
use English;
use Errno    qw( EINTR EAGAIN EWOULDBLOCK ENOBUFS EBADMSG );
use Log::Any qw( $log );
use IO::Socket;
use Role::Tiny qw( requires );

requires qw(
  enqueue
  cancel
  handle_writable
  handle_readable
  want_read
  want_write
  io_handle
);

1;
