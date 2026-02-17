package Zonemaster::Engine::Async::DispatcherResult;
use v5.26;
use warnings;

use Carp qw( croak );

sub task_ok {
    my ( $class, %args ) = @_;
    my (    #
        $task_id,
        $message,
      )
      = delete @args{
        qw(
          task_id
          message
        )
      };
    my $obj = {
        variant => 'task_ok',
        task_id => $task_id,
        message => $message,
    };
    return bless $obj, $class;
}

sub task_timeout {
    my ( $class, %args ) = @_;
    my (    #
        $task_id,
      )
      = delete @args{
        qw(
          task_id
        )
      };
    my $obj = {
        variant => 'task_timeout',
        task_id => $task_id,
    };
    return bless $obj, $class;
}

sub read_error {
    my ( $class, %args ) = @_;
    my (    #
        $proto,
        $peer_ip,
        $error,
      )
      = delete @args{
        qw(
          proto
          peer_ip
          error
        )
      };
    my $obj = {
        variant => 'read_error',
        proto   => $proto,
        peer_ip => $peer_ip,
        error   => $error,
    };
    return bless $obj, $class;
} ## end sub read_error

sub write_error {
    my ( $class, %args ) = @_;
    my (    #
        $proto,
        $peer_ip,
        $error,
      )
      = delete @args{
        qw(
          proto
          peer_ip
          error
        )
      };
    my $obj = {
        variant => 'write_error',
        proto   => $proto,
        peer_ip => $peer_ip,
        error   => $error,
    };
    return bless $obj, $class;
} ## end sub write_error

1;
