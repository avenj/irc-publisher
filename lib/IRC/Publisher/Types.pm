package IRC::Publisher::Types;

use strictures 2;

use Type::Library   -base;
use Type::Utils     -all;

use Types::Standard       -types;
use List::Objects::Types  -types;

use Net::CIDR::Set;

declare CIDRSet =>
  as InstanceOf['Net::CIDR::Set'];
coerce CIDRSet =>
  from ArrayRef() => via { Net::CIDR::Set->new(@$_) },
  from ArrayObj() => via { Net::CIDR::Set->new($_->all) };

1;
