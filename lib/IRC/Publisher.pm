package IRC::Publisher;

use Carp;
use strictures 1;

use IRC::Message::Object    'ircmsg';

use List::Objects::Types    -types;
use POEx::ZMQ::Types        -types;
use Types::Standard         -types;

use JSON::MaybeXS;

use POE;
use POEx::ZMQ;
use POEx::IRC::Backend;

use Try::Tiny;

use Moo 1.006;

has session_id => (
  init_arg    => undef,
  is          => 'ro',
  writer      => '_set_session_id',
  clearer     => '_clear_session_id',
  predicate   => '_has_session_id',
  builder     => sub { undef },
);

# Configurables
has publish_on => (
  required    => 1,
  is          => 'ro',
  isa         => TypedArray[ZMQEndpoint],
  coerce      => 1,
);

has listen_on => (
  lazy        => 1,
  is          => 'ro',
  isa         => TypedArray[ZMQEndpoint],
  coerce      => 1,
  predicate   => 1,
  builder     => sub { [] },
);

has handle_ping => (
  is          => 'ro',
  isa         => Bool,
  builder     => sub { 1 },
);


# Backends
has irc => (
  lazy        => 1,
  is          => 'ro',
  isa         => InstanceOf['POEx::IRC::Backend'], 
  builder     => sub { POEx::IRC::Backend->spawn },
);

has json => (
  lazy        => 1,
  is          => 'ro',
  isa         => HasMethods[qw/new encode/],
  builder     => sub {
    JSON::MaybeXS->new(
      utf8            => 1,
      allow_nonref    => 1,
      convert_blessed => 1,
    )
  }
);


has _alias => (
  # alias => POEx::IRC::Backend::Connect
  lazy        => 1,
  is          => 'ro',
  isa         => HashObj,
  coerce      => 1,
  clearer     => 1,
  builder     => sub { +{} },
);


# ZeroMQ bits
has zmq => (
  lazy        => 1,
  is          => 'ro',
  isa         => InstanceOf['POEx::ZMQ'],
  builder     => sub { POEx::ZMQ->new },
);

has zmq_sock_pub => (
  lazy        => 1,
  is          => 'ro',
  isa         => ZMQSocket[ZMQ_PUB],
  builder     => sub {
    my ($self) = @_;
    $self->zmq->socket(type => ZMQ_PUB)
  },
);

has zmq_sock_router => (
  lazy        => 1,
  is          => 'ro',
  isa         => ZMQSocket[ZMQ_ROUTER],
  builder     => sub {
    my ($self) = @_;
    $self->zmq->socket(
      type          => ZMQ_ROUTER,
      event_prefix  => 'zrtr_',
    )
  },
);

sub BUILD {
  my ($self) = @_;
  POE::Session->create(
    object_states => [
      $self => [ qw/
        _start
        _stop
        _session_cleanup
        _zrtr_recv_multipart
      / ],
      $self => +{
        ircsock_input             => '_ircsock_input',
        ircsock_connector_open    => '_ircsock_open',
        ircsock_connector_failure => '_ircsock_failed',
        ircsock_disconnect        => '_ircsock_disconnect',
      },
    ],
  )
}

sub _start {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  $self->_set_session_id( $_[SESSION]->ID );

  $kernel->post( $self->irc->session_id => 'register' );

  $self->zmq_sock_pub->start;
  $self->zmq_sock_router->start;

  $self->publish_on->visit(sub { $self->zmq_sock_pub->bind($_) });
  $self->listen_on->visit(sub { $self->zmq_sock_router->bind($_) });
}

sub _stop {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  $self->_clear_session_id;
}

sub stop {
  my ($self) = @_;
  $poe_kernel->post( $self->irc->session_id => 'shutdown' );
  $poe_kernel->post( $self->session_id, '_session_cleanup' );
  $self->zmq_sock_pub->stop;
  $self->zmq_sock_router->stop;
}

sub _session_cleanup {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  $kernel->alarm_remove_all;
}

sub publish {
  my ($self, $prefix, @parts) = @_;
  $self->zmq_sock_pub->send_multipart( $prefix, @parts );
}

sub aliases {
  my ($self) = @_;
  $self->_alias->keys->all
}

sub connect {
  my ($self, %params) = @_;

  for (qw/alias addr/) {
    croak "Missing required parameter '$_'"
      unless defined $params{$_}
  }

  croak 'Alias must be in the [A-Za-z0-9_-] set'
    unless $params{alias} =~ /^[A-Za-z0-9_-]$/;
  
  $self->backend->create_connector(
    tag => $params{alias},

    remoteaddr => $params{addr},
    remoteport => ($params{port} // 6667),

    ipv6  => $params{ipv6},
    # FIXME bindaddr, configurable irc_from_addr attr
  );
}

sub disconnect {
  my ($self, $alias) = @_;

  my $conn = $self->_alias->get($alias)
    || confess "No such alias '$alias'";
  $self->irc->disconnect($conn->wheel_id, 'Disconnecting');
}

sub send {
  my ($self, $alias, $ircmsg) = @_;

  my $conn = $self->_alias->get($alias)
    || confess "No such alias '$alias'";
  $self->irc->send($ircmsg, $conn);
}


sub _ircsock_input {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($conn, $msg) = @_[ARG0 .. $#_];

  if (lc $msg->command eq 'ping' && $self->handle_ping) {
    $self->send(
      ircmsg(
        command => 'pong',
        params  => [ @{ $msg->params } ],
      ),
      $conn
    );
    return
  }

  $self->publish( ircmsg => $self->json->encode($msg) );
}

sub _ircsock_open {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $conn = $_[ARG0];
  my $alias = $conn->args->{tag}
    || confess "BUG - Connect obj is missing alias tag";
  $self->_alias->set($alias => $conn);
  $self->publish( ircstatus => connected => $alias );
}

sub _ircsock_failed {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($connector, $op, $errno, $errstr) = @_[ARG0 .. $#_];
  my $alias = $connector->args->{tag}
    || confess "BUG - Connector obj is missing alias tag";
  $self->_alias->delete($alias);
  $self->publish( ircstatus => failed => $alias, $op, $errno, $errstr );
}

sub _ircsock_disconnect {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $conn = $_[ARG0];
  my $alias = $conn->args->{tag}
    || confess "BUG - Connector obj is missing alias tag";
  $self->_alias->delete($alias);
  $self->publish( ircstatus => disconnected => $alias );
}


sub _zrtr_recv_multipart {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $msg = $_[ARG0];
  my $envelope = $msg->items_before(sub { ! length });
  my $body     = $msg->items_after(sub { ! length });

  my ($id, $cmd, $json) = $body->all;

  my $meth = '_cmd_' . lc($cmd // 'bad_input');
  my $output = try {
    my $params = $json ? $self->json->decode($json) : +{};
    die [404 => 'Command not handled'] unless $self->can($meth);
    $self->$meth($id, $params)
  } catch {
    ref $_ eq 'ARRAY' ? 
      +{ code => $_->[0], msg => $_->[1], id => $id }
      : +{ code => 500, msg => "$_", id => $id }
  };

  if ($output) {
    my $js_reply = $self->json->encode($output);
    $self->zmq_sock_router->send_multipart(
      [ $envelope->all, '', $js_reply ]
    )
  }
}

sub _cmd_bad_input {
  my ($self, $maybe_id) = @_;
  +{ code => 500, msg => "Invalid message format", id => $maybe_id // 0 }
}

sub _cmd_connect {
  my ($self, $id, $params) = @_;
  $self->connect(%$params);
  +{ code => 200, msg => "ACK CONNECT", id => $id }
}

sub _cmd_disconnect {
  my ($self, $id, $params) = @_;
  my $alias = delete $params->{alias} // die "Missing required param 'alias'";
  $self->disconnect($alias);
  +{ code => 200, msg => "ACK DISCONNECT", id => $id }
}

sub _cmd_send {
  my ($self, $id, $params) = @_;
  my $alias = delete $params->{alias} // die "Missing required param 'alias'";
  my $ircmsg = ircmsg(%$params);
  $self->send($alias => $ircmsg);
  +{ code => 200, msg => "ACK SEND", id => $id }
}

sub _cmd_aliases {
  my ($self, $id) = @_;
  +{ code => 200, msg => $self->_alias->keys->join(' '), id => $id }
}

sub _cmd_ping {
  my ($self, $id) = @_;
  +{ code => 200, msg => 'PONG', $id }
}


1;

=pod

=head1 NAME

IRC::Publisher - Bridge IRC and ZeroMQ to build extensible clients or servers

=head1 SYNOPSIS

FIXME

=head1 DESCRIPTION

=head2 PUBLISHED EVENTS

=head3 ircmsg

=head3 ircstatus

=head2 ATTRIBUTES

=head3 publish_on

=head3 listen_on

=head3 handle_ping

=head3 irc

=head3 json

=head3 zmq

=head3 zmq_sock_pub

=head3 zmq_sock_router

=head2 METHODS

=head3 stop

=head3 aliases

=head3 connect

=head3 disconnect

=head3 publish

=head3 send

=head2 REMOTE COMMAND INTERFACE

=head3 aliases

=head3 connect

=head3 disconnect

=head3 send

=head3 ping

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

=cut
