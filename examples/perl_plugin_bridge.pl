#!/usr/bin/env perl

use strictures 1;

package My::PluginPlatform;

# A simplistic plugin dispatch system for use with an IRC::Publisher:

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
    plugins   => array(@{ $params{plugins} || [] }),

    # 'publisher =>' is the IRC::Publisher's PUB endpoint:
    publisher => ($params{publisher} || die "Expected 'publisher =>'"),

    # 'remote =>' is the IRC::Publisher's ROUTER endpoint:
    remote    => ($params{remote} || die "Expected 'remote =>'"),

    # 'nick =>' is the desired IRC nickname as a string:
    nick      => ($params{nick} || die "Expected 'nick =>'"),

    # 'server =>' is an IRC server as a string:
    server    => ($params{server} || die "Expected 'server =>'"),

    # 'channels =>' is an ARRAY of channels to join:
    channels  => array(@{ $params{channels} || die "Expected 'channels =>'" }),

    # We want a JSON that can handle ->TO_JSON for objects:
    _json     => JSON::MaybeXS->new(
      allow_nonref => 1, convert_blessed => 1, utf8 => 1
    ),

    # Store a POEx::ZMQ instance for spawning shared-context sockets later:
    _zmq      => POEx::ZMQ->new,
    _msgid    => 0,

  };

  # DEALER will talk to IRC::Publisher's ROUTER command interface:
  $self->{_zdealer} = $self->{_zmq}->socket(
    type          => ZMQ_DEALER,
    event_prefix  => '_zdealer_',
  );

  # SUB will listen for IRC events from IRC::Publisher:
  $self->{_zsub} = $self->{_zmq}->socket(
    type          => ZMQ_SUB,
    event_prefix  => '_zsub_',
  );

  # SUB will subscribe to all events:
  $self->{_zsub}->set_sock_opt(ZMQ_SUBSCRIBE, '');

  bless $self, $class;

  POE::Session->create(
    object_states => [
      $self => [ qw/
        _start
        _zdealer_recv_multipart
        _zsub_recv_multipart

        ev_send_irc_connect
        ev_send_irc_registration
        ping
      / ],
    ],
  );

  $self
}

# Some basic accessors:
sub publisher { shift->{publisher} }
sub remote   { shift->{remote} }
sub plugins  { shift->{plugins} }
sub nick     { shift->{nick} }
sub channels { shift->{channels} }
sub server   { shift->{server} }

sub _json    { shift->{_json} }
sub _zdealer { shift->{_zdealer} }
sub _zsub    { shift->{_zsub} }

sub send_to_irc {
  my $self = shift;
  for my $ircmsg (@_) {
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
      [ '', $msgid, send => $json ]
    );
  }
}

sub _start {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  #  Connect to configured PUB & DEALER:
  $self->_zsub->connect( $self->publisher );
  $self->_zdealer->connect( $self->remote );
  # Subscribe to all messages from PUB:
  $self->_zsub->set_socket_opt(ZMQ_SUBSCRIBE, '');
  # Delay in case subscribing is slow, then we'll issue our commands:
  $kernel->delay( ev_send_irc_connect => 1 );
  # Start ping timer; we'll reset it whenever we have traffic:
  $kernel->delay( ping => 60 );
}

sub stop {
  # FIXME kill timers, issue shutdown to sockets
}

sub ev_send_irc_connect {
  my $self = $_[OBJECT];

  my $msgid = $self + 0;

  my $json = $self->_json->encode(
    +{ alias => 'irc', addr => $self->server }
  );

  $self->_zdealer->send_multipart(
    [ '', $msgid, connect => $json ]
  );
}

sub ev_send_irc_registration {
  my $self = $_[OBJECT];
  $self->send_to_irc(
    ircmsg(
      command => 'user',
      params  => [
        'ircpub',   # username
        '*', '*',   # unused in modern ircds
        'IRC::Publisher example' # realname
      ],
    ),

    ircmsg(
      command => 'nick',
      params  => [ $self->nick ],
    )
  );
}

sub ping {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $msgid = time;
  if ($self->{_ping_pending}) {
    # Still waiting on a reply on our last ping; timeout.
    warn "Ping timeout on remote ROUTER, exiting";
    # A real app would probably try to recreate the socket;
    # we just quit:
    $self->stop;
  }

  $self->{_ping_pending} = 1;

  $self->_zdealer->send_multipart(
    [ '', $msgid, 'ping' ]
  );

  $kernel->delay( ping => 60 );
}

sub _zdealer_recv_multipart {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $parts = $_[ARG0];

  # We have traffic, so we can reset our ping timeout:
  $kernel->delay( ping => 60 );

  # Extract message envelope & body, decode JSON:
  my $envelope  = $parts->items_before(sub { ! length });
  my $body      = $parts->items_after(sub { ! length });
  my $json      = $body->get(0);
  my $response  = $self->_json->decode($json);

  if ($response->{code} == 500) {
    my $err = $response->{msg};
    warn "WARNING; error from remote IRC::Publisher: $err\n";
    return
  }

  if ($response->{code} == 200 && $response->{msg} eq 'ACK') {
    my $cmd = $response->{data};
    print "Publisher acknowledged command: $cmd\n";
  }

  if ($response->{msg} eq 'PONG') {
    $self->{_ping_pending} = 0;
  }
}

sub _zsub_recv_multipart {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $parts = $_[ARG0];
  
  # Publisher sends [ $type, @params ]:
  my $type = $parts->shift;
  
  if ($type eq 'ircstatus') {
    my $event = $parts->shift;
    if ($event eq 'connected') {
      # Connection established, try to register:
      $kernel->yield('ev_send_irc_registration');
      return
    }
    if ($event eq 'failed' || $event eq 'disconnected') {
      die "IRC quit: $event => ".$parts->join(', ')."\n"
    }
    warn "ircstatus: $event => ".$parts->join(', ')."\n";
  }

  if ($type eq 'ircmsg') {
    # Fetch our JSON-ified IRC message:
    my $json    = $parts->get(0);
    # Then turn it back into a blessed IRC::Message::Object:
    my $data    = $self->_json->decode($json);
    my $ircmsg  = ircmsg(%$data);

    if ($ircmsg->command eq '001') {
      # If this is a 001 numeric, send our JOINs:
      $self->channels->natatime(4, sub {
        $self->send_to_irc(
          ircmsg( command => 'join', params => [ join ',', @_ ] )
        )
      });
      return
    }

    # Trivial plugin dispatch via List::Objects::WithUtils;
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

use Getopt::Long;
my %opts;
my @required = qw/remote publisher nick server channels/;
GetOptions( \%opts, 
  help => sub {
    print "$0\n\n",
      "  --remote=ENDPOINT\n",
      "  --publisher=ENDPOINT\n",
      "  --nick=NICKNAME\n",
      "  --server=ADDR\n",
      "  --channels=CHAN[,CHAN, ...]\n",
      "\n"
    ;
    exit 0
  },

  map {; $_ eq 'channels' ? $_.'=s@' : $_.'=s' } @required,
);
for (@required) {
  my $pname = '--'.$_;
  die "Missing required parameter '$pname'" unless defined $opts{$_}
}

$opts{channels} = [ split /,/, join ',', @{ $opts{channels} } ];

my $platform = My::PluginPlatform->new(
  plugins => [ My::Plugin::Hello->new, My::Plugin::ShowRawLines->new ],
  %opts
);

POE::Kernel->run
