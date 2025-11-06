#!/usr/bin/env perl
use v5.26;
use warnings;

use Registry qw( msg step steps scenario );

scenario 'tc fallback' => steps {
    step( 'client.add_request' )
      ->args( msg => msg( qname => 'example.com', qtype => 'SOA' ), _eids => [1] )
      ->expect( eid => 1 );
    step( 'client.poll_events' )
      ->args( _eids => [] )
      ->expect( events => [] );
    step( 'server.receive' )
      ->expect( msg => msg( qid => 1, qname => 'example.com', qtype => 'SOA' ) );
    step( 'server.send' )
      ->args( msg => msg( qid => 1, qr => 1, tc => 1, qname => 'example.com', qtype => 'SOA' ) );
    step( 'client.poll_events' )
      ->args( _eids => [2] )
      ->expect( events => [] );
    step( 'server.accept_tcp' );
    step( 'server.receive' )
      ->expect( msg => msg( qid => 2, qname => 'example.com', qtype => 'SOA' ) );
    step( 'server.send' )
      ->args( msg => msg( qid => 2, qr => 1, qname => 'example.com', qtype => 'SOA' ) );
    step( 'client.poll_events' )
      ->args( _eids => [] )
      ->expect( events => [ { eid => 1, msg => msg( qid => 2, qr => 1, qname => 'example.com', qtype => 'SOA' ) } ] );
};
