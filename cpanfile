requires "perl"       => "5.008";
requires "strictures" => "1";

requires "List::Objects::Types" => "1";
requires "Moo"                => "1.006";
requires "Types::Standard"    => "0";

requires "JSON::MaybeXS"      => "0";
requires "Try::Tiny"          => "0";

requires "POEx::ZMQ"          => "0.005";
requires "POEx::IRC::Backend" => "0.026";


on 'test'      => sub {
  requires "Test::More" => "0.88";
};
