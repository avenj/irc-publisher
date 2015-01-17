#!/usr/bin/env perl

use strictures 1;

package My::PluginPlatform;

use JSON::MaybeXS 'decode_json';
use IRC::Message::Object 'ircmsg';
use List::Objects::WithUtils;

use POE;
use POEx::ZMQ;

sub new {
  my ($class, %params) = @_;

  my $self = +{
    # Simplistic plugins; constructor 'plugins =>' parameter is an ARRAY of
    # plugin objects:
    plugins  => array(@{ $params{plugins} || [] }),

    # 'nick =>' is the desired IRC nickname as a string:
    nick     => ($params{nick} || die "Expected 'nick =>'"),

    # 'server =>' is an IRC server as a string:
    server   => ($params{server} || die "Expected 'server =>'"),

    # 'channels =>' is an ARRAY of channels to join:
    channels => array(@{ $params{channels} || die "Expected 'channels =>'" }),

    # We want a JSON that can handle ->TO_JSON for objects:
    _json    => JSON::MaybeXS->new(
      allow_nonref => 1, convert_blessed => 1, utf8 => 1
    ),

    # Store a POEx::ZMQ instance for spawning shared-context sockets later:
    _zmq     => POEx::ZMQ->new,
    _msgid   => 0,

  };

  # DEALER will talk to IRC::Publisher's ROUTER command interface:
  $self->{_zdealer} = $self->{_zmq}->socket(type => ZMQ_DEALER);
  # SUB will listen for IRC events from IRC::Publisher:
  $self->{_zsub} = $self->{_zmq}->socket(type => ZMQ_SUB);

  bless $self, $class;

  POE::Session->create(
    object_states => [
      $self => [ qw/
        _start
        _zdealer_recv_multipart
        _zpub_recv_multipart
      / ],
    ],
  );

  $self
}

sub plugins {
  my ($self) = @_;
  $self->{plugins}
}

sub send_to_irc {
  my ($self, $ircmsg) = @_;
  # FIXME SEND cmd on DEALER
}

sub _start {
  # FIXME set up / start sockets
  # FIXME start ping timer
}

sub _zdealer_recv_multipart {
  my $parts = $_[ARG0];
  my $envelope  = $parts->items_before(sub { ! length });
  my $body      = $parts->items_after(sub { ! length });
  my $json      = $body->get(0);

  # FIXME these should be command ACKs 
}

sub _zpub_recv_multipart {
  my $parts = $_[ARG0];
  
  # Publisher sends [ $type, @params ]:
  my $type = shift;
  
  if ($type eq 'ircstatus') {
    # Just print 'ircstatus' messages:
    warn "ircstatus: ".$parts->join(' => ');
    return
  }

  if ($type eq 'ircmsg') {
    # Fetch our JSON-ified IRC message:
    my $json    = $parts->get(0);
    # Then turn it back into a blessed IRC::Message::Object:
    my $data    = decode_json($json);
    my $ircmsg  = ircmsg(%$data);

    # Trivial "plugin" dispatch via List::Objects::WithUtils;
    # visit each object in ->plugins and dispatch to '_cmd_foo' or '_default':
    $self->plugins->visit(sub {
      my $meth = '_cmd_'.lc($ircmsg->command);
      # If the plugin has this method (or '_default') and the method returns
      # something, feed it to ->send_to_irc()
      unless ( $_->can($meth) ) {
        return unless $_->can('_default');
        $meth = '_default'
      }
      if (my $result = $_->$meth($ircmsg)) {
        $self->send_to_irc($result)
      }      
    });
  }
}



package My::Plugin::Hello;

sub _cmd_privmsg {
  my ($self, $ircmsg) = @_;
  # FIXME reply to 'hello' or 'hi' by returning new ircmsg
}


package My::Plugin::ShowRawLines;

sub _default {
  my ($self, $ircmsg) = @_;
  print " [raw line: '", $ircmsg->raw_line, "']\n";
  ()
}

package main;

# FIXME construct PluginPlatform w/ Hello + ShowRawLines plugins

POE::Kernel->run
# FIXME
#  - spawn session
#  - SUB to specified --publisher
#  - DEALER to specified --server
#  - start PING timer
#    - reset timer on incoming traffic
#    - send [ID, PING] via DEALER when timer fires
#    - if timer fires but still $_[HEAP]->waiting_on_pong,
#      die for ping timeout
#  - send CONNECT for specified --server
#  - send JOIN for specified --channel(s)
#  - display incoming 'ircstatus' msgs
#  - dispatch incoming 'ircmsg' events to plugin pipeline
#  - provide a 'HelloWorld' and 'ShowRawLines' plugin inline
