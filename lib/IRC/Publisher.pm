package IRC::Publisher::Publisher;

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

  $kernel->post( $self->irc->session_id => 'register' );

  $self->zmq_sock_pub->start;
  $self->zmq_sock_router->start;

  $self->publish_on->visit(sub { $self->zmq_sock_pub->bind($_) });
  $self->listen_on->visit(sub { $self->zmq_sock_router->bind($_) });
}

sub stop {
  # FIXME ->disconnect & shut down emitters
}

sub publish {
  my ($self, $prefix, @parts) = @_;
  $self->zmq_sock_pub->send_multipart( $prefix, @parts );
}


sub connect {
  my ($self, %params) = @_;

  my @required = qw/alias addr/;
  for (@required) {
    confess "Missing required parameter '$_'"
      unless defined $params{$_}
  }
  
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

  # FIXME
}

sub send {
  my ($self, $alias, $ircmsg) = @_;

  my $conn = $self->_alias->get($alias)
    || confess "No such alias '$alias'";
  $self->irc->send($ircmsg, $conn);
}


sub _ircsock_input {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $msg = $_[ARG1];

  # FIXME if ->handle_ping (default 1),
  #  handle ping-pong dialog, throw these away
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
  # FIXME delete our alias if present
}

sub _ircsock_disconnect {
  # FIXME delete our alias if present
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
    $self->$meth($id, $params)
  } catch {
    +{ code => 500, msg => "$_", id => $id }
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
  # FIXME
}

sub _cmd_send {
  my ($self, $id, $params) = @_;
  my $alias = delete $params->{alias} // die "Missing required param 'alias'";
  my $ircmsg = ircmsg(%$params);
  $self->send($alias => $ircmsg);
  +{ code => 200, msg => "ACK SEND", id => $id }
}

sub _cmd_aliases {
  # FIXME
}


1;
