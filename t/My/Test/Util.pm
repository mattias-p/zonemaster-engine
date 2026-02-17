package My::Test::Util;
use v5.26;
use warnings;

use Data::Dump::Filtered qw( dump_filtered );
use Exporter             qw( import );

our @EXPORT_OK = qw(
  describe
);

=head2 describe

Stringify a hierarchical data structure.

Nodes are stringified using a L<Data::Dumper>-like syntax, with a 1000 character maximum
line-width. For nodes that support the C<short> method, that method is called to provide a
stand-in for the node itself.

=cut

sub describe {
    my ( $data ) = @_;

    my $filter = sub {
        my ( $ctx, $objref ) = @_;

        return ( $ctx->is_blessed && $objref->can( 'short' ) )
          ? { dump => $objref->short }
          : ();
    };

    local $Data::Dump::LINEWIDTH = 1000;

    return dump_filtered( $data, $filter );
}

1;
