requires "strictures" => "2";

requires "App::bmkpasswd" => "2";

requires "List::Objects::Types"     => "1";
requires "Moo"                      => "2";
requires "Types::Standard"          => "0";

requires "JSON::MaybeXS"      => "0";
requires "Try::Tiny"          => "0";

requires "POEx::IRC::Backend" => "0.026";


on 'test'      => sub {
  requires "Test::More" => "0.88";
};
