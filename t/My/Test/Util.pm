package My::Test::Util;
use v5.26;
use warnings;

use Data::Dump::Filtered qw( dump_filtered );
use Exporter             qw( import );

our @EXPORT_OK = qw(
  describe
);

sub describe {
    my ( $hash ) = @_;

    my $filter = sub {
        my ( $ctx, $objref ) = @_;

        return ( $ctx->is_blessed && $objref->can( 'short' ) )
          ? { dump => $objref->short }
          : ();
    };

    local $Data::Dump::LINEWIDTH = 1000;

    return dump_filtered( $hash, $filter );
}

