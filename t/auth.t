use Test::More;
use strict; use warnings;

sub PASSWD () { 'bar' }

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
my $pwd = bcrypt->crypt(PASSWD);
$auth->add_account( foo => $pwd );
my $ret = $auth->check('1.2.3.4', foo => PASSWD);
ok $ret->allowed, '->check->allowed (1.2.3.4 + passwd)';
cmp_ok $ret->message, 'eq', 'allow', '->check->message (1.2.3.4 + passwd)'
  or diag explain $ret;
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
