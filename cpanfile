requires "perl"       => "5.008";
requires "strictures" => "1";

on 'configure' => sub {};
on 'build'     => sub {};
on 'test'      => sub {
  requires "Test::More" => "0.88";
};
on 'runtime'   => sub {};
on 'develop'   => sub {};
