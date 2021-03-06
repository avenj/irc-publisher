package IRC::Publisher::Auth;

use Carp;
use strictures 2;

use App::bmkpasswd 'passwdcmp';

use List::Objects::WithUtils;

use List::Objects::Types  -types;
use Types::Standard       -types;
use IRC::Publisher::Types -types;

use Moo;

# TODO: pluggable auth backends

has _valid_policies => (
  is        => 'ro',
  isa       => HashObj,
  coerce    => 1,
  builder   => sub {
    +{ map {; $_ => 1 } qw/ -blacklist -whitelist -passwd / }
  },
);

has policy => (
  # Auth policy in force; ordered by priority
  is        => 'ro',
  isa       => ImmutableArray,
  coerce    => 1,
  writer    => 'set_policy',
  builder   => sub {
    [ -blacklist, -passwd ]
  },
  trigger   => 1,
);

sub _trigger_policy {
  my ($self, $policy) = @_;
  for my $chkpolicy (@$policy) {
    confess "Auth policy '$chkpolicy' not a known policy"
      unless $self->_valid_policies->exists($chkpolicy)
  }
}


has accounts => (
  # For -passwd auth policy; $account -> $crypted (bcrypt/sha/md5)
  is        => 'ro',
  isa       => HashObj,
  coerce    => 1,
  builder   => sub { +{} },
);

sub account_names { shift->accounts->keys }

sub add_account {
  my ($self, $acct, $passwd) = @_;
  confess "Expected account name and (crypt) password"
    unless defined $acct and defined $passwd;
  carp "Warning; replacing existing account '$acct'"
    if $self->accounts->exists($acct);
  $self->accounts->set($acct => $passwd);
  $self
}

sub del_account {
  my ($self, $acct) = @_;
  confess "Expected account name" unless defined $acct;
  unless ( $self->accounts->exists($acct) ) {
    carp "Cannot del_account nonexistant account '$acct'";
    return
  }
  $self->accounts->delete($acct);
  $self
}


has _addr_blacklist => (
  is        => 'ro',
  isa       => CIDRSet,
  coerce    => 1,
  builder   => sub { [] },
);

sub get_blacklist { array(shift->_addr_blacklist->as_cidr_array) }

sub blacklist {
  my ($self, @addrs) = @_;
  confess "->blacklist expected an address" unless @addrs;
  $self->_addr_blacklist->add(@addrs);
  $self
}

sub unblacklist {
  my ($self, @addrs) = @_;
  confess "->unblacklist expected an address" unless @addrs;
  # Net::CIDR::Set doesn't care if these exist or not ->
  $self->_addr_blacklist->remove(@addrs);
  $self
}

sub is_blacklisted {
  my ($self, $addr) = @_;
  confess "->is_blacklisted expected an address" unless defined $addr;
  return if $self->_addr_blacklist->is_empty;
  $self->_addr_blacklist->contains($addr)
}


has _addr_whitelist => (
  is        => 'ro',
  isa       => CIDRSet,
  coerce    => 1,
  builder   => sub { [] },
);

sub get_whitelist { array(shift->_addr_whitelist->as_cidr_array) }

sub whitelist {
  my ($self, @addrs) = @_;
  confess "->whitelist expected an address" unless @addrs;
  $self->_addr_whitelist->add(@addrs);
  $self
}

sub unwhitelist {
  my ($self, @addrs) = @_;
  confess "->unwhitelist expected an address" unless @addrs;
  $self->_addr_whitelist->remove(@addrs);
  $self
}

sub is_whitelisted {
  my ($self, $addr) = @_;
  confess "->is_whitelisted expected an address" unless defined $addr;
  return if $self->_addr_whitelist->is_empty;
  $self->_addr_whitelist->contains($addr)
}


{ package
    IRC::Publisher::AuthReturnValue;
  sub new { my $class = shift; bless [@_], $class }
  sub allowed { shift->[0] }
  sub message { shift->[1] }
}

sub _auth_retval {
  IRC::Publisher::AuthReturnValue->new(@_)
}

sub check {
  # Returns [$bool, $info_string] with ->allowed & ->message accessors
  my ($self, $addr, @params) = @_;
  
  POLICY: for my $chkpolicy ($self->policy->all) {
    my $dispatch_to = substr $chkpolicy, 1;
    my $meth = "_check_${dispatch_to}";
    confess "BUG; no such method '$meth' for policy '$chkpolicy'"
      unless $self->can($meth);
    my $ret = $self->$meth($addr, @params);
    $ret->[0] ? next POLICY : return _auth_retval(@$ret)
  }

  _auth_retval(1, 'allow')
}

sub _check_whitelist {
  my ($self, $addr) = @_;
  $self->is_whitelisted($addr) ? [1, 'allow'] : [0, 'not whitelisted']
}

sub _check_blacklist {
  my ($self, $addr) = @_;
  $self->is_blacklisted($addr) ? [0, 'blacklisted'] : [1, 'allow']
}

sub _check_passwd {
  my ($self, undef, $acct, $passwd) = @_;
  return [0, 'bad params'] unless defined $acct and defined $passwd;
  return [0, 'unknown account'] unless $self->accounts->exists($acct);
  my $crypt = $self->accounts->get($acct);
  return [1, 'allow'] if passwdcmp($passwd => $crypt);
  [0, 'bad passwd']
}

1;
