package IRC::Publisher::Publisher;

use Carp;
use strictures 1;

use List::Objects::Types    -types;
use POEx::ZMQ::Types        -types;
use Types::Standard         -types;

use JSON::MaybeXS;

use POE;
use POEx::ZMQ;
use POEx::IRC::Backend;


use Moo::Role; use MooX::late;

has 

has irc => (
  lazy        => 1,
  is          => 'ro',
  isa         => InstanceOf['POEx::IRC::Backend'], 
  builder     => sub { POEx::IRC::Backend->spawn },
);

has json => (
  lazy        => 1,
  is          => 'ro',
  isa         => HandlesMethods[qw/new encode/],
  builder     => sub {
    JSON::MaybeXS->new(
      utf8            => 1,
      allow_nonref    => 1,
      convert_blessed => 1,
    )
  }
);

has _zmq => (
  lazy        => 1,
  is          => 'ro',
  isa         => InstanceOf['POEx::ZMQ'],
  builder     => sub { POEx::ZMQ->new },
);

has _zpub => (
  lazy        => 1,
  is          => 'ro',
  isa         => ZMQSocket[ZMQ_PUB],
  builder     => sub {
    # FIXME
  },
);

has _zrtr => (
  lazy        => 1,
  is          => 'ro',
  isa         => ZMQSocket[ZMQ_ROUTER],
  builder     => sub {
    # FIXME ZMQ::Socket w/ 'zrtr_' event prefix
  },
);

sub BUILD {
  my ($self) = @_;
  # FIXME set up session
  POE::Session->create(
    object_states => [
      $self => [ qw/
        _start
      / ],
      $self => +{
        ircsock_input       => '_ircsock_input',
        zrtr_recv_multipart => '_zrtr_recv_multipart',
      },
    ],
  )
}

sub _start {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  # FIXME irc->start
  # FIXME post 'register' to Backend
  # FIXME set up backend connector(s)

  # FIXME set up relevant ROUTER / PUB binds
}

sub stop {
  # FIXME ->disconnect & shut down emitters
}

sub connect {

}

sub disconnect {

}

sub publish {
  my ($self, $prefix, @parts) = @_;
  $self->_zpub->send_multipart( $prefix, @parts );
}

sub _ircsock_input {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $msg = $_[ARG1];

  $self->publish( ircmsg => $self->json->encode($msg) );
}

sub _zrtr_recv_multipart {
  # FIXME dispatch commands
}

1;
