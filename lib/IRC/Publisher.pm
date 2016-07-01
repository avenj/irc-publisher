package IRC::Publisher;


# FIXME consider turning me into an Emitter ?
# - pros
#  pluggability & filtering options before hitting subscribers
# - cons
#  encourages Doing Too Much in Publisher

use Carp;
use strictures 2;

use List::Objects::Types    -types;
use Types::Standard         -types;

use IRC::Message::Object    'ircmsg';

use JSON::MaybeXS;

use POE;
use POEx::IRC::Backend;

use Try::Tiny;


use Moo;

has session_id => (
  init_arg    => undef,
  is          => 'ro',
  writer      => '_set_session_id',
  clearer     => '_clear_session_id',
  predicate   => '_has_session_id',
  builder     => sub { undef },
);

has publish_on_addr => (
  lazy        => 1,
  is          => 'ro',
  isa         => Str,
  builder     => sub { '127.0.0.1' },
);

has publish_on_port => (
  lazy        => 1,
  is          => 'ro',
  isa         => Int,
  builder     => sub { '9090' },
);

has pub_ping_delay => (
  is          => 'ro',
  isa         => StrictNum,
  builder     => sub { 30 },
);

has handle_irc_ping => (
  is          => 'ro',
  isa         => Bool,
  builder     => sub { 1 },
);


# Backends
#  FIXME private _irc / _pub ?
has irc => (
  lazy        => 1,
  is          => 'ro',
  isa         => InstanceOf['POEx::IRC::Backend'], 
  builder     => sub { POEx::IRC::Backend->spawn },
);

# FIXME set up ->pub POEx::IRC::Backend
# FIXME use line filter only and speak straight JSON pub-side?
#  (or line + JSON filter)
#  FIXME protocol doc

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
  # aliases for IRC-facing active Connects;
  # +{ $alias => POEx::IRC::Backend::Connect }
  lazy        => 1,
  is          => 'ro',
  isa         => HashObj,
  coerce      => 1,
  clearer     => 1,
  builder     => sub { +{} },
);


sub BUILD {
  my ($self) = @_;
  POE::Session->create(
    object_states => [
      $self => [ qw/
        _start
        _stop
        _session_cleanup
        _pub_ping
        _pub_ping_timer
      / ],
      $self => +{
        # FIXME these are shared between pub & irc backends;
        #  we need to suss out which is which based on $_[SENDER]
        #  & dispatch accordingly 
        #  $_[SENDER] ==
        #   ->irc->session_id       # published as ircmsg events
        #   ->pub->session_id # sent to command dispatcher
        # Shared:
        ircsock_input             => '_ircsock_input',
        ircsock_disconnect        => '_ircsock_disconnect',
        # Connector-only:
        ircsock_connector_open    => '_ircsock_irc_connected',
        ircsock_connector_failure => '_ircsock_irc_failed',
        # Listener-only: FIXME
      },
    ],
  )
}

sub _start {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  $self->_set_session_id( $_[SESSION]->ID );

  $kernel->post( $self->pub->session_id => 'register' );
  $kernel->post( $self->irc->session_id => 'register' );

  $self->pub->create_listener(
    # FIXME optional ipv6
    # FIXME optional ssl, default-on
    
    bindaddr => $self->publish_on_addr,
    port     => $self->publish_on_port,
    idle     => $self->pub_ping_delay,
  );

  # Start PUB ping timer ->
  $kernel->yield( '_pub_ping_timer' );
}

sub _stop {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  $self->_clear_session_id;
}

sub stop {
  my ($self) = @_;
  # FIXME publish shutdown status, disconnect open listener connects
  $poe_kernel->post( $self->pub->session_id => 'shutdown' );
  $poe_kernel->post( $self->irc->session_id => 'shutdown' );
  $poe_kernel->post( $self->session_id => '_session_cleanup' );
}

sub _session_cleanup {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  $kernel->alarm_remove_all;
}

sub _pub_ping {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  # send a PING if we haven't spoken in a while,
  # our subscribers will know we're not dead ->
  $self->publish( ping => time );
  $kernel->yield( '_pub_ping_timer' );
}

sub _pub_ping_timer {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  $kernel->delay( _pub_ping => $self->pub_ping_delay );
}

sub send {
  my ($self, $alias, $ircmsg) = @_;
  my $conn = $self->_alias->get($alias)  || confess "No such alias '$alias'";
  $self->irc->send($ircmsg, $conn);
}

sub publish {
  my ($self, $prefix, @parts) = @_;

  # FIXME ->send to all seen ->pub Connects  (tracked in attr ?)
  # FIXME JSONify 
  # FIXME enforce refs-only ?

  # Reset ping timer
  $poe_kernel->post( $self->session_id, '_pub_ping_timer' );
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
    unless $params{alias} =~ /^[A-Za-z0-9_-]+$/;
  
  $self->irc->create_connector(
    tag => $params{alias},

    remoteaddr => $params{addr},
    remoteport => ($params{port} // 6667),

    ipv6  => $params{ipv6},
    # FIXME bindaddr, configurable irc_from_addr attr
  );
  # FIXME publish event indicating we're connecting out
}

sub disconnect {
  my ($self, $alias) = @_;
  my $conn = $self->_alias->get($alias) || confess "No such alias '$alias'";
  # FIXME publish event indicating we're disconnecting
  #  (and a confirmation event when we get ircsock_disconnect)
  $self->irc->disconnect($conn->wheel_id, 'Disconnecting');
}


sub _ircsock_disconnect {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $conn = $_[ARG0];
  # FIXME these could be irc or pub side, handle cleanup appropriately
  my $alias = $conn->args->{tag}
    || confess "BUG - Connector obj is missing alias tag";
  $self->_alias->delete($alias);
  $self->publish( ircstatus => disconnected => $alias );
}

sub INPUT_FROM_IRC () { 0 }
sub INPUT_FROM_PUB () { 1 }

sub _ircsock_input {
  my ($kernel, $sender, $self) = @_[KERNEL, SENDER, OBJECT];
  my ($conn, $msg) = @_[ARG0 .. $#_];

  my $from = 
      $sender == $self->pub->session_id ? INPUT_FROM_PUB
    : $sender == $self->irc->session_id ? INPUT_FROM_IRC
    : confess "BUG; _ircsock_input from unknown session ID '$sender'"
  ;

  # Ping response handler for both sides; returns params as-is
  if (lc $msg->command eq 'ping') {
    HANDLE_PING: {
      last HANDLE_PING 
        if $from == INPUT_FROM_IRC and not $self->handle_irc_ping;
      $self->post( $sender, send =>
        ircmsg(
          command => 'pong',
          params  => [ @{ $msg->params } ],
        ),
        $conn
      );
      return 1
    } # HANDLE_PING
  }

  if ($from == INPUT_FROM_PUB) {
    # FIXME incoming from pub-side, dispatch to cmd handler
  } elsif ($from == INPUT_FROM_IRC) {
    # FIXME incoming from IRC-side, publish ircmsg
    # FIXME ircmsg dispatch should suss out which $alias this $conn belongs to
    #       (attach metadata to $conn->args)
  }

}

# FIXME handle:
#  ircsock_connection_idle  (only applies to pub-side listens)
#   -> mandate ping/pong heartbeating, kill if we get connection_idle twice?
#  ircsock_listener_failure (pub failed to open port(s))
#  ircsock_listener_open    (pub accepted a new connect we need to track)
#     * auth handshake for new connects
#       -> Auth.pm stackable auth pipeline, could probably use
#          MooX::Role::Pluggable for this (poex-irc-backend loads it anyway)
#     * ping timer(s) for new connects? or publish a ping to all at interval
#   -> fix disconnect handling, both hit ircsock_disconnect

sub _ircsock_irc_connected {
  # Outgoing open -- on our ->irc backend presumably
  #  (though TODO; outgoing ->pub connects ?)
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $conn = $_[ARG0];
  my $alias = $conn->args->{tag}
    || confess "BUG - Connect obj is missing alias tag";
  $self->_alias->set($alias => $conn);
  $self->publish( ircstatus => connected => $alias );
}

sub _ircsock_irc_failed {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($connector, $op, $errno, $errstr) = @_[ARG0 .. $#_];
  my $alias = $connector->args->{tag}
    || confess "BUG - Connector obj is missing alias tag";
  $self->_alias->delete($alias);
  $self->publish( ircstatus => failed => $alias, $op, $errno, $errstr );
}



sub _zrtr_recv_multipart {
  # FIXME kill this in favor of incoming pub-side message handler
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
  +{ code => 200, msg => "ACK", data => "CONNECT", id => $id }
}

sub _cmd_disconnect {
  my ($self, $id, $params) = @_;
  my $alias = delete $params->{alias} // die "Missing required param 'alias'";
  $self->disconnect($alias);
  +{ code => 200, msg => "ACK", data => "DISCONNECT", id => $id }
}

sub _cmd_send {
  my ($self, $id, $params) = @_;
  my $alias = delete $params->{alias} // die "Missing required param 'alias'";
  my $ircmsg = ircmsg(%$params);
  $self->send($alias => $ircmsg);
  +{ code => 200, msg => "ACK", data => "SEND", id => $id }
}

sub _cmd_aliases {
  my ($self, $id) = @_;
  +{ 
    code  => 200, 
    msg   => "ALIASES", 
    data  => $self->_alias->keys->join(' '),
    id    => $id 
  }
}

sub _cmd_ping {
  my ($self, $id) = @_;
  +{ code => 200, msg => 'PONG', $id }
}


1;

=pod

=head1 NAME

IRC::Publisher - A distributed approach to IRC applications

=head1 SYNOPSIS

FIXME

=head1 DESCRIPTION

This module provides a way to build IRC clients or servers composed of
discrete components potentially implemented in (m)any languages (and possibly
distributed across a network, etc). 

There is no state-tracking and very little IRC protocol negotiation; the
intention is for a higher-level layer to handle the details of communication
with the server (see C<examples/> in this distribution).

=head2 PUBLISHED EVENTS

=head3 ircmsg

=head3 ircstatus

=head2 ATTRIBUTES

=head3 publish_on

=head3 listen_on

=head3 handle_irc_ping

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
