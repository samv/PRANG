
package PRANG::Graph::Meta::Element;

use Moose::Role;
use PRANG::Util qw(types_of);
use MooseX::Method::Signatures;

has 'xmlns' =>
	is => "rw",
	isa => "Str",
	predicate => "has_xmlns",
	;

has 'xml_nodeName' =>
	is => "rw",
	isa => "Str|HashRef",
	predicate => "has_xml_nodeName",
	;

has 'xml_nodeName_attr' =>
	is => "rw",
	isa => "Str",
	predicate => "has_xml_nodeName_attr",
	;

has 'xml_required' =>
	is => "rw",
	isa => "Bool",
	predicate => "has_xml_required",
	;

has 'xml_min' =>
	is => "rw",
	isa => "Int",
	predicate => "has_xml_min",
	;

has 'xml_max' =>
	is => "rw",
	isa => "Int",
	predicate => "has_xml_max",
	;

# FIXME: see commitlog, core Moose should get support for this again
#        (perhaps)
#has '+isa' =>
#	required => 1,
#	;

has 'graph_node' =>
	is => "rw",
	isa => "PRANG::Graph::Node",
	lazy => 1,
	required => 1,
	default => sub {
		my $self = shift;
		$self->build_graph_node;
	},
	;

use constant HIGHER_ORDER_TYPE =>
	"Moose::Meta::TypeConstraint::Parameterized";

method error(Str $message) {
	my $class = $self->associated_class;
	my $context = " (Element: ";
	if ( $class ) {
		$context .= $class->name;
	}
	else {
		$context .= "(unassociated)";
	}
	$context .= "/".$self->name.") ";
	die $message.$context;
}

method build_graph_node() {
	my ($expect_one, $expect_many);

	if ( $self->has_xml_required ) {
		$expect_one = $self->xml_required;
	}
	elsif ( $self->has_predicate ) {
		$expect_one = 0;
	}
	else {
		$expect_one = 1;
	}

	my $t_c = $self->type_constraint
		or $self->error(
		"No type constraint on attribute; did you specify 'isa'?",
		       );

	# check to see whether ArrayRef was specified
	if ( $t_c->is_a_type_of("ArrayRef") ) {
		my $is_paramd;
		until ( $t_c->equals("ArrayRef") ) {
			if ( $t_c->isa(HIGHER_ORDER_TYPE) ) {
				$is_paramd = 1;
				last;
			}
			else {
				$t_c = $t_c->parent;
			}
		}
		if (not $is_paramd) {
			$self->error("ArrayRef, but not Parameterized");
		}
		$expect_many = 1;

		$t_c = $t_c->type_parameter;
	}

	# ok.  now let's walk the type constraint tree, and look for
	# types
	my ($expect_bool, $expect_simple, @expect_type, @expect_role);

	my @st = $t_c;
	my %t_c;
	while ( my $x = shift @st ) {
		$t_c{$x} = $x;
		if ( $x->isa("Moose::Meta::TypeConstraint::Class") ) {
			push @expect_type, $x->class;
		}
		elsif ( $x->isa("Moose::Meta::TypeConstraint::Union") ) {
			push @st, @{ $x->parents };
		}
		elsif ( $x->isa("Moose::Meta::TypeConstraint::Enum") ) {
			$expect_simple = 1;
		}
		elsif ( $x->isa("Moose::Meta::TypeConstraint::Role") ) {
			# likely to be a wildcard.
			push @expect_role, $x->role;
		}
		elsif ( ref $x eq "Moose::Meta::TypeConstraint" ) {
			if ( $x->equals("Bool") ) {
				$expect_bool = 1;
			}
			elsif ( $x->equals("Value") ) {
				$expect_simple = 1;
			}
			else {
				push @st, $x->parent;
			}
		}
		else {
			$self->error("Sorry, I don't know how to map a "
					     .ref($x));
		}
	}

	my $node;
	my $nodeName = $self->has_xml_nodeName ?
		$self->xml_nodeName : $self->name;

	my $expect_concrete = ($expect_bool||0) +
		($expect_simple||0) + @expect_type;

	if ( $expect_concrete > 1 ) {
		# multiple or ambiguous types are specified; we *need*
		# to know
		if ( ! ref $nodeName ) {
			$self->error(
			"type union specified, but no nodename map given"
				);
		}
		while ( my ($nodeName, $type) = each %$nodeName ) {
			if ( not exists $t_c{$type} ) {
				$self->error(
"nodeName to type map specifies $nodeName => '$type', but $type is not"
						." an acceptable type",
				       );
			}
		}
	}

	# plug-in type classes.
	if ( @expect_role ) {
		my @users = map { $_->name } types_of(@expect_role);
		$nodeName = {} if !ref $nodeName;
		for my $user ( @users ) {
			if ( $user->does("PRANG::Graph") ) {
				my $root_element = $user->root_element;
				if ( exists $nodeName->{$root_element} ) {
					$self->error(
"Both '$user' and '$nodeName->{$root_element}' plug-in type specify $root_element root_element, not supported",
					       );
				}
				$nodeName->{$root_element} = $user;
			}
			elsif ( $user->does("PRANG::Graph::Class") ) {
				if ( !$self->has_xml_nodeName_attr ) {
					$self->error(
"Can't use role(s) @expect_role; no xml_nodeName_attr",
					       );
				}
			}
			else {
				$self->error(
"Can't use role(s) @expect_role; no mapping",
					);
			}
			push @expect_type, $user;
		}
		$self->xml_nodeName({%$nodeName});
	}
	if ( !ref $nodeName and $expect_concrete ) {
		my $expected = $expect_bool ? "Bool" :
			$expect_simple ? "Str" : $expect_type[0];
		$nodeName = { $nodeName => $expected };
	}
	elsif ( $expect_concrete ) {
		$nodeName = { %$nodeName };
	}

	my @expect;
	for my $class ( @expect_type ) {
		my @xmlns;
		if ( $self->has_xmlns ) {
			push @xmlns, (xmlns => $self->xmlns);
		}
		else {
			my $xmlns = $self->associated_class->name->xmlns;
			if ( !$class->can("xmlns") ) {
				my $ok = eval "use $class; 1";
				if ( !$ok ) {
					die "problem auto-including class '$class'; exception is: $@";
				}
			}
			if ( !$class->meta->can("marshall_in_element") ) {
				die "'$class' can't marshall in; did you 'use PRANG::Graph'?";
			}
			if ( ($class->xmlns||"") ne ($xmlns||"") ) {
				push @xmlns, (xmlns => ($class->xmlns||""));
			}
		}
		my (@names) = grep { $nodeName->{$_} eq $class }
			keys %$nodeName;

		if ( !@names ) {
			die "type '$class' specified as allowed on '"
	.$self->name."' element of ".$self->associated_class->name
	.", but which node names indicate that type?  You've defined: "
	.($self->has_xml_nodeName
	? ( ref $self->xml_nodeName
	    ? join("; ", map { "$_ => ".$self->xml_nodeName->{$_} }
		      sort keys %{$self->xml_nodeName} )
	    : ("(all '".$self->xml_nodeName."')") )
	: "(nothing)" );
		}

		for my $name ( @names ) {
			push @expect, PRANG::Graph::Element->new(
				@xmlns,
				attrName => $self->name,
				nodeClass => $class,
				nodeName => $name,
			       );
			delete $nodeName->{$name};
		}
	}

	if ( $expect_bool ) {
		my (@names) = grep {
			!$t_c{$nodeName->{$_}}->is_a_type_of("Object")
		} keys %$nodeName;

		# 'Bool' elements are a shorthand for the element
		# 'maybe' being there.
		for my $name ( @names ) {
			push @expect, PRANG::Graph::Element->new(
				attrName => $self->name,
				attIsArray => $expect_many,
				nodeName => $name,
			       );
			delete $nodeName->{$name};
		}
	}
	if ( $expect_simple ) {
		my (@names) = grep {
			my $t_c = $t_c{$nodeName->{$_}};
			die "dang, ".$self->name." of ".$self->associated_class->name.", no type constraint called $nodeName->{$_} (element $_)"
				if !$t_c;
			!$t_c->is_a_type_of("Object")
		} keys %$nodeName;
		for my $name ( @names ) {
			# 'Str', 'Int', etc element attributes: this
			# means an XML data type: <attr>value</attr>
			if ( !length($name) ) {
				# this is for 'mixed' data
				push @expect, PRANG::Graph::Text->new(
					attrName => $self->name,
				       );
			}
			else {
				# regular XML data style
				push @expect, PRANG::Graph::Element->new(
					attrName => $self->name,
					nodeName => $name,
					contents => PRANG::Graph::Text->new,
				       );
			}
			delete $nodeName->{$name};
		}
	}

	# FIXME - sometimes, xml_nodeName_attr is not needed, and
	# setting it breaks things - it's only needed if the nodeName
	# map is ambiguous.
	my @name_attr =
		(($self->has_xml_nodeName_attr ? 
			  ( name_attr => $self->xml_nodeName_attr ) : ()),
		 (($self->has_xml_nodeName and ref $self->xml_nodeName) ?
			  ( type_map => {%{$self->xml_nodeName}} ) : ()),
		);

	if ( @expect > 1 ) {
		$node = PRANG::Graph::Choice->new(
			choices => \@expect,
			attrName => $self->name,
			@name_attr,
		       );
	}
	else {
		$node = $expect[0];
		if ( $self->has_xml_nodeName_attr ) {
			$node->nodeName_attr($self->xml_nodeName_attr);
		}
	}

	if ( $expect_bool ) {
		$expect_one = 0;
	}

	# deal with limits
	if ( !$expect_one or $expect_many) {
		my @min_max;
		if ( $expect_one and !$self->has_xml_min ) {
			$self->xml_min(1);
		}
		if ( $self->has_xml_min ) {
			push @min_max, min => $self->xml_min;
		}
		if ( !$expect_many and !$self->has_xml_max ) {
			$self->xml_max(1);
		}
		if ( $self->has_xml_max ) {
			push @min_max, max => $self->xml_max;
		}
		die "no node!  fail!  processing ".$self->associated_class->name.", element ".$self->name unless $node;
		$node = PRANG::Graph::Quantity->new(
			@min_max,
			attrName => $self->name,
			child => $node,
		       );
	}
	else {
		$self->xml_min(1);
		$self->xml_max(1);
	}

	return $node;
}

package Moose::Meta::Attribute::Custom::Trait::PRANG::Element;
sub register_implementation {
	"PRANG::Graph::Meta::Element";
};

1;

=head1 NAME

PRANG::Graph::Meta::Element - metaclass metarole for XML elements

=head1 SYNOPSIS

 use PRANG::Graph;

 has_element 'somechild' =>
    is => "rw",
    isa => "Some::Type",
    xml_required => 0,
    ;

 # equivalent alternative - plays well with others!
 has 'somechild' =>
    is => "rw",
    traits => [qr/PRANG::Element/],
    isa => "Some::Type",
    xml_required => 0,
    ;

=head1 DESCRIPTION

The PRANG concept is that attributes in your classes are marked to
correspond with attributes and elements in your XML.  This class is
for marking your class' attributes as XML I<elements>.  For marking
them as XML I<attributes>, see L<PRANG::Graph::Meta::Attr>.

Non-trivial elements - and this means elements which contain more than
a single TextNode element within - are mapped to Moose classes.  The
child elements that are allowed within that class correspond to the
attributes marked with the C<PRANG::Element> trait, either via
C<has_element> or the Moose C<traits> keyword.

Where it makes sense, as much as possible is set up from the regular
Moose definition of the attribute.  This includes the XML node name,
the type constraint, and also the predicate.

If you like, you can also set the C<xmlns> and C<xml_nodeName>
attribute property, to override the default behaviour, which is to
assume that the XML element name matches the Moose attribute name, and
that the XML namespace of the element is that of the I<value> (ie,
C<$object-E<gt>somechild-E<gt>xmlns>.

The B<order> of declaring element attributes is important.  They
implicitly define a "sequence".  To specify a "choice", you must use a
union sub-type - see below.  Care must be taken with bundling element
attributes into roles as ordering when composing is not defined.

The B<predicate> property of the attribute is also important.  If you
do not define C<predicate>, then the attribute is considered
I<required>.  This can be overridden by specifying C<xml_required> (it
must be defined to be effective).

The B<isa> property (B<type constraint>) you set via 'isa' is
I<required>.  The behaviour for major types is described below.  The
module knows about sub-typing, and so if you specify a sub-type of one
of these types, then the behaviour will be as for the type on this
list.  Only a limited subset of higher-order/parametric/structured
types are permitted as described.

=over 4

=item B<Bool  sub-type>

If the attribute is a Bool sub-type (er, or just "Bool", then the
element will marshall to the empty element if true, or no element if
false.  The requirement that C<predicate> be defined is relaxed for
C<Bool> sub-types.

ie, C<Bool> will serialise to:

   <object>
     <somechild />
   </object>

For true and

   <object>
   </object>

For false.

=item B<Scalar sub-type>

If it is a Scalar subtype (eg, an enum, a Str or an Int), then the
value of the Moose attribute is marshalled to the value of the element
as a TextNode; eg

  <somechild>somevalue</somechild>

=item B<Object sub-type>

If the attribute is an Object subtype (ie, a Class), then the element
is serialised according to the definition of the Class defined.

eg, with;

   {
       package CD;
       use Moose; use PRANG::Graph;
       has_element 'author' => qw( is rw isa Person );
       has_attr 'name' => qw( is rw isa Str );
   }
   {
       package Person;
       use Moose; use PRANG::Graph;
       has_attr 'group' => qw( is rw isa Bool );
       has_attr 'name' => qw( is rw isa Str );
       has_element 'deceased' => qw( is rw isa Bool );
   }

Then the object;

  CD->new(
    name => "2Pacalypse Now",
    author => Person->new(
       group => 0,
       name => "Tupac Shakur",
       deceased => 1,
       )
  );

Would serialise to (assuming that there is a L<PRANG::Graph> document
type with C<cd> as a root element):

  <cd name="2Pacalypse Now">
    <author group="0" name="Tupac Shakur>
      <deceased />
    </author>
  </cd>

=item B<ArrayRef sub-type>

An C<ArrayRef> sub-type indicates that the element may occur multiple
times at this point.  Bounds may be specified directly - the
C<xml_min> and C<xml_max> attribute properties.

Higher-order types are supported; in fact, to not specify the type of
the elements of the array is a big no-no.

If C<xml_nodeName> is specified, it refers to the items; no array
container node is expected.

For example;

  has_attr 'name' =>
     is => "rw",
     isa => "Str",
     ;
  has_attr 'releases' =>
     is => "rw",
     isa => "ArrayRef[CD]",
     xml_min => 0,
     xml_nodeName => "cd",
     ;

Assuming that this property appeared in the definition for 'artist',
and that CD C<has_attr 'title'...>, it would let you parse:

  <artist>
    <name>The Headless Chickens</name>
    <cd title="Stunt Clown">...<cd>
    <cd title="Body Blow">...<cd>
    <cd title="Greedy">...<cd>
  </artist>

You cannot (currently) Union an ArrayRef type with other simple types.

=item B<Union types>

Union types are special; they indicate that any one of the types
indicated may be expected next.  By default, the name of the element
is still the name of the Moose attribute, and if the case is that a
particular element may just be repeated any number of times, this is
fine.

However, this can be inconvenient in the typical case where the
alternation is between a set of elements which are allowed in the
particular context, each corresponding to a particular Moose type.
Another one is the case of mixed XML, where there may be text, then
XML fragments, more text, more XML, etc.

There are two relevant questions to answer.  When marshalling OUT, we
want to know what element name to use for the attribute in the slot.
When marshalling IN, we need to know what element names are allowable,
and potentially which sub-type to expect for a particular element
name.

After applying much DWIMery, the following scenarios arise;

=over

=item B<1:1 mapping from Type to Element name>

This is often the case for message containers that allow any number of
a collection of classes inside.  For this case, a map must be provided
to the C<xml_nodeName> function, which allows marshalling in and out
to proceed.

  has_element 'message' =>
      is => "rw",
      isa => "my::unionType",
      xml_nodeName => {
          "nodename" => "TypeA",
          "somenode" => "TypeB",
      };

It is an error if types are repeated in the map.  The empty string can
be used as a node name for text nodes, otherwise they are not allowed.

This case is made of win because no extra attributes are required to
help the marshaller; the type of the data is enough.

An example of this in practice;

  subtype "My::XML::Language::choice0"
     => as join("|", map { "My::XML::Language::$_" }
                  qw( CD Store Person ) );

  has_element 'things' =>
     is => "rw",
     isa => "ArrayRef[My::XML::Language::choice0]",
     xml_nodeName => +{ map {( lc($_) => $_ )} qw(CD Store Person) },
     ;

This would allow the enclosing class to have a 'things' property,
which contains all of the elements at that point, which can be C<cd>,
C<store> or C<person> elements.

In this case, it may be preferrable to pass a role name as the element
type, and let this module evaluate construct the C<xml_nodeName> map
itself.

=item B<more types than element names>

This happens when some of the types have different XML namespaces; the
type of the node is indicated by the namespace prefix.

In this case, you must supply a namespace map, too.

  has_element 'message' =>
      is => "rw",
      isa => "my::unionType",
      xml_nodeName => {
          "trumpery:nodename" => "TypeA",
          "rubble:nodename" => "TypeB",
          "claptrap:nodename" => "TypeC",
      },
      xml_nodeName_prefix => {
          "trumpery" => "uri:type:A",
          "rubble" => "uri:type:B",
          "claptrap" => "uri:type:C",
      },
      ;

B<FIXME:> this is currently unimplemented.

=item B<more element names than types>

This can happen for two reasons: one is that the schema that this
element definition comes from is re-using types.  Another is that you
are just accepting XML without validation (eg, XMLSchema's
C<processContents="skip"> property).  In this case, there needs to be
another attribute which records the names of the node.

  has_element 'message' =>
      is => "rw",
      isa => "my::unionType",
      xml_nodeName => {
          "nodename" => "TypeA",
          "somenode" => "TypeB",
          "someother" => "TypeB",
      },
      xml_nodeName_attr => "message_name",
      ;

If any node name is allowed, then you can simply pass in C<*> as an
C<xml_nodeName> value.

=item B<more namespaces than types>

The principle use of this is L<PRANG::XMLSchema::Whatever>, which
converts arbitrarily namespaced XML into objects.  In this case,
another attribute is needed, to record the XML namespaces of the
elements.

  has 'nodenames' =>
	is => "rw",
	isa => "ArrayRef[Maybe[Str]]",
        ;

  has 'nodenames_xmlns' =>
	is => "rw",
	isa => "ArrayRef[Maybe[Str]]",
	;

  has_element 'contents' =>
      is => "rw",
      isa => "ArrayRef[PRANG::XMLSchema::Whatever|Str]",
      xml_nodeName => { "" => "Str", "*" => "PRANG::XMLSchema::Whatever" },
      xml_nodeName_attr => "nodenames",
      xml_nodeName_xmlns_attr => "nodenames_xmlns",
      xmlns => "*",
      ;

B<FIXME:> this is currently unimplemented.

=item B<unknown/extensible element names and types>

These are indicated by specifying a role.  At the time that the
L<PRANG::Graph::Node> is built for the attribute, the currently
available implementors of these roles are checked, and depending on
whether they implement L<PRANG::Graph> or merely
L<PRANG::Graph::Class>, the following actions are taken:

=over

=item L<PRANG::Graph> types

Treated as if there is an C<xml_nodeName> entry for the class, from
the C<root_element> value for the class to the type.  B<FIXME>: to
also include the XML namespace of the class.

For writing extensible schemas, this is generally the role you want to
inherit.

=item L<PRANG::Graph::Class> types

B<FIXME:> this entry may be out of date, please ignore for the time
being.

You must supply C<xml_nodeName_attr>.  This type will never be used on
marshall in; however, it will happily work on the way out.

This can be used when you have slots which may be unprocessed,
L<PRANG::XMLSchema::Whatever> object structures, B<or> real
L<PRANG::Graph::Class> instances.

eg

  has 'maybe_parsed' =>
      is => "rw",
      isa => "PRANG::Graph::Whatever|PRANG::Graph::Class",
      xml_nodeName_attr => "maybe_parsed_name",
      ;

=back

=back

=back

=head1 SEE ALSO

L<PRANG::Graph::Meta::Attr>, L<PRANG::Graph::Meta::Element>,
L<PRANG::Graph::Node>

=head1 AUTHOR AND LICENCE

Development commissioned by NZ Registry Services, and carried out by
Catalyst IT - L<http://www.catalyst.net.nz/>

Copyright 2009, 2010, NZ Registry Services.  This module is licensed
under the Artistic License v2.0, which permits relicensing under other
Free Software licenses.

=cut
