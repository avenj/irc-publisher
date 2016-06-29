use Test::More;
use strict; use warnings;

use Crypt::Bcrypt::Easy;
use IRC::Publisher::Auth;

my $auth = IRC::Publisher::Auth->new;

# ->policy
is_deeply $auth->policy->unbless, [ -blacklist, -passwd ],
  'default policy: -blacklist, -passwd';

# ->accounts
is_deeply $auth->accounts->keys->unbless, [],
  '->accounts empty by default';
# ->add_account
my $pwd = bcrypt->crypt('foo');
$auth->add_account( foo => $pwd );
ok $auth->check('1.2.3.4', foo => $pwd), '->check 1.2.3.4 + passwd';
# ->del_account
# ->account_names
# FIXME

# ->blacklist
# ->is_blacklisted
# ->unblacklist
# ->get_blacklist
# FIXME

# ->whitelist
# ->is_whitelisted
# ->unwhitelist
# ->get_whitelist
# FIXME

# ->check
# FIXME

done_testing
