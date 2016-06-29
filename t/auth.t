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

# ->account_names
$auth->add_account( bar => $pwd );
is_deeply $auth->account_names->sort->unbless, [ 'bar', 'foo' ],
  'account_names';

# ->del_account
ok $auth->del_account( 'bar' ), 'del_account';
is_deeply $auth->account_names->unbless, ['foo'],
  'account_names after del_account';

# ->blacklist
# ->is_blacklisted
# ->unblacklist
# ->get_blacklist
# FIXME
# FIXME explicit test for blacklisted but passwd ok on ->check

# ->whitelist ( FIXME enable whitelist policy )
# ->is_whitelisted
# ->unwhitelist
# ->get_whitelist
# FIXME

# ->check
# FIXME

# FIXME policy combinations

done_testing
