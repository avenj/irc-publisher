#!/usr/bin/env perl

use strictures 1;

# A simplistic plugin dispatch system for use with an IRC::Publisher:
package My::PluginPlatform;

use JSON::MaybeXS;
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

        send_irc_connect
      / ],
    ],
  );

  $self
}

# Some basic accessors:
sub plugins  { shift->{plugins} }
sub nick     { shift->{nick} }
sub channels { shift->{channels} }
sub server   { shift->{server} }

sub _json    { shift->{_json} }
sub _zdealer { shift->{_zdealer} }
sub _zsub    { shift->{_zsub} }

sub send_to_irc {
  my ($self, $ircmsg) = @_;
  # Message IDs are for your application's purpose and need not be globally
  # unique; that is, the IRC::Publisher has no interest in these except to tag
  # replies. We just use our message's refaddr, which is braindead but simple
  # enough:
  my $msgid = $ircmsg + 0;

  # An IRC::Message::Object provides ->TO_JSON:
  my $json = $self->_json->encode($ircmsg);

  # Our DEALER sends:
  #  empty routing delimiter,
  #  arbitrary message ID,
  #  command,
  #  JSON
  $self->_zdealer->send_multipart(
    '', $msgid, send => $json 
  );
}

sub _start {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  # FIXME set up / start sockets
  #  connect
  #  subscribe to ''
  # FIXME start ping timer
  # FIXME delay in case of slow subscriber, then
  #       issue IRC connect + send JOIN when we get _001 in recv
}

sub send_irc_connect {
  my $self = $_[OBJECT];

  my $msgid = $self + 0;

  my $json = $self->_json->encode(
    +{ alias => 'irc', addr => $self->server }
  );

  $self->_zdealer->send_multipart(
    '', $msgid, connect => $json
  );
}

sub _zdealer_recv_multipart {
  my $self  = $_[OBJECT];
  my $parts = $_[ARG0];
  # Extract message envelope & body:
  my $envelope  = $parts->items_before(sub { ! length });
  my $body      = $parts->items_after(sub { ! length });
  my $json      = $body->get(0);
  my $response  = $self->_json->decode($json);
  # FIXME these should be command ACKs or a pong
}

sub _zpub_recv_multipart {
  my $self  = $_[OBJECT];
  my $parts = $_[ARG0];
  
  # Publisher sends [ $type, @params ]:
  my $type = shift;
  
  if ($type eq 'ircstatus') {
    # FIXME if ircstatus is 'connected', send registration
    # FIXME if connector failure, quit
    warn "ircstatus: ".$parts->join(' => ');
    return
  }

  if ($type eq 'ircmsg') {
    # Fetch our JSON-ified IRC message:
    my $json    = $parts->get(0);
    # Then turn it back into a blessed IRC::Message::Object:
    my $data    = $self->_json->decode($json);
    my $ircmsg  = ircmsg(%$data);

    # FIXME if command is 001, issue JOIN and skip plugin dispatch

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

# A plugin that responds to greetings:
package My::Plugin::Hello;

sub new { bless [], shift }

sub _cmd_privmsg {
  my ($self, $ircmsg) = @_;
  my $prefix = substr $ircmsg->params->[0], 0, 1;
  if (grep {; $_ eq $prefix } '#', '&', '+') {
    return ircmsg(
      command => 'privmsg',
      params  => [ $ircmsg->params->[0], "hello there!" ]
    ) if $ircmsg->params->[1] =~ /^(hi|hello)/;
  }
  ()
}


# A plugin that shows incoming raw lines:
package My::Plugin::ShowRawLines;

sub new { bless [], shift }

sub _default {
  my ($self, $ircmsg) = @_;
  print " [raw line: '", $ircmsg->raw_line, "']\n";
  ()
}


# Construct and run our PluginPlatform:
package main;
my $platform = My::PluginPlatform->new(
  plugins => [ My::Plugin::Hello->new, My::Plugin::ShowRawLines->new ],
);
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
