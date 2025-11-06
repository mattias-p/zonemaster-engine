package Step;
use v5.26;
use warnings;

use Carp       qw( croak );
use List::Util qw( min );

sub new {
    my ( $class, %args ) = @_;

    my (    #
        $origin,
        $verb,
        $arg_validators,
        $expect_validators,
      )
      = delete @args{
        qw(
          origin
          verb
          arg_validators
          expect_validators
        )
      };

    defined $verb && ref $verb eq ''
      or croak "verb must be a defined scalar";
    ref $arg_validators eq 'HASH'
      or croak "arg_validators must be a HASH";
    ref $expect_validators eq 'HASH'
      or croak "expect_validators must be a HASH";

    my $obj = {
        _origin  => $origin,
        _verb    => $verb,
        _args    => undef,
        _expects => undef,
    };
    return bless $obj, $class;
} ## end sub new

sub _validate {
    my ( $prefix, $validators, %args ) = @_;

    my %validators = $validators->%*;
    my @missing;

    for my $verb ( sort keys %validators ) {
        if ( !exists $args{$verb} ) {
            push @missing, $verb;
            next;
        }
        my $value = delete $args{$verb};
        $validators->{$verb}->check( $prefix . $verb, $value );
    }

    if ( %args ) {
        croak "unrecognized args: " . join( ', ', sort keys %args );
    }

    if ( @missing ) {
        croak "missing args: " . join( ', ', @missing );
    }

    return;
} ## end sub _validate

sub verb_meta {
    my ( $self ) = @_;

    return $Registry::VERBS{ $self->{_verb} };
}

sub args {
    my ( $self, %args ) = @_;

    my $validators = $self->verb_meta->{arg_validators};

    _validate( "args.", $validators, %args );

    $self->{_args} = \%args;

    return $self;
}

sub expect {
    my ( $self, %args ) = @_;

    my $validators = $self->verb_meta->{expect_validators};

    _validate( "expect.", $validators, %args );

    $self->{_expects} = \%args;

    return $self;
}

package Registry;
use v5.26;
use warnings;

use Carp            qw( croak );
use Exporter        qw( import );
use Scalar::Util    qw( looks_like_number );
use Type::Utils     qw( as declare where );
use Types::Standard qw( ArrayRef Int Undef );

our @EXPORT_OK = qw( step steps );

my $Uint = declare as Int, where { $_ >= 0 };
my $Msg  = declare as Undef;

sub msg {
    return undef;
}

our %VERBS = (    #
    'client.add_request' => {
        arg_validators => {
            _eids => ArrayRef [$Uint],
            msg   => $Msg,
        },
        expect_validators => {
            eid => $Uint,
        },
    },
    'client.poll_events' => {
        arg_validators => {
            _eids => ArrayRef [$Uint],
        },
        expect_validators => {
            events => ArrayRef [$Uint],
        },
    },
    'server.receive' => {
        arg_validators    => {},
        expect_validators => {
            msg => $Msg,
        },
    },
    'server.send' => {
        arg_validators => {
            msg => $Msg,
        },
        expect_validators => {},
    },
    'server.accept_tcp' => {
        arg_validators    => {},
        expect_validators => {},
    },
);

use Data::Dumper;

sub scenario {
    my ( @steps ) = @_;

    for my $step ( @steps ) {
        print Dumper ( $step );
    }

    return;
}

our $steps;

sub steps (&) {
    my ( $sub ) = @_;

    local $steps;
    $steps = [];
    $sub->();

    for my $step ( $steps->@* ) {
        if ( !defined $step->{_args} ) {
            my $validators = $VERBS{ $step->{_verb} }{arg_validators};
            if ( $validators->%* ) {
                croak sprintf( '%s @ %s: missing args: ',
                    $step->{_verb}, $step->{_origin}, join( ', ', sort keys $validators->%* ) );
            }
        }
        else {
            $step->{_args} = {};
        }

        if ( !defined $step->{_expects} ) {
            my $validators = $VERBS{ $step->{_verb} }{expect_validators};
            if ( $validators->%* ) {
                croak sprintf( '%s @ %s: missing expect args: %s',
                    $step->{_verb}, $step->{_origin}, join( ', ', sort keys $validators->%* ) );
            }
        }
        else {
            $step->{_expects} = {};
        }
    } ## end for my $step ( $steps->...)

    return $steps->@*;
} ## end sub steps (&)

sub step {
    my ( $verb ) = @_;

    if ( !defined $steps ) {
        croak 'must be called in the context of steps';
    }

    my ( undef, $file, $line ) = caller();
    my $origin = "$file:$line";

    exists $VERBS{$verb}
      or croak 'unrecognized step verb';

    my $step = Step->new(
        origin => $origin,
        verb   => $verb,
        $VERBS{$verb}->%*,
    );

    push $steps->@*, $step;

    return $step;
} ## end sub step

package My::Test;
use v5.26;
use warnings;

sub step {
    goto \&Registry::step;
}

sub steps (&) {
    goto \&Registry::steps;
}

sub msg {
    goto \&Registry::msg;
}

sub scenario {
    goto \&Registry::scenario;
}

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
