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
$ret = $auth->check('1.2.3.4', foo => 'badpasswd');
ok !$ret->allowed, '->check->allowed negative (bad passwd)';

# ->account_names
$auth->add_account( bar => $pwd );
is_deeply $auth->account_names->sort->unbless, [ 'bar', 'foo' ],
  'account_names';
$ret = $auth->check('1.2.3.4', bar => PASSWD);
ok $ret->allowed, '->check->allowed (after add_account)';

# ->del_account
ok $auth->del_account( 'bar' ), 'del_account';
is_deeply $auth->account_names->unbless, ['foo'],
  'account_names after del_account';
$ret = $auth->check('1.2.3.4', bar => PASSWD);
ok !$ret->allowed, '->check->allowed negative (after del_account)';

# ->blacklist / is_blacklisted
ok !$auth->is_blacklisted('127.0.0.1'), 'negative is_blacklisted (empty bl)';
$auth->blacklist('127.0.0.1', '192.168.0.1/16');
ok $auth->is_blacklisted('127.0.0.1'), 'is_blacklisted (single)';
ok $auth->is_blacklisted('192.168.0.3'), 'is_blacklisted (range)';
ok !$auth->is_blacklisted('200.0.0.1'), 'negative is_blacklisted';
# ->unblacklist
$auth->unblacklist('127.0.0.1');
ok !$auth->is_blacklisted('127.0.0.1'), 'is_blacklisted after unblacklist';
ok $auth->is_blacklisted('192.168.0.4'), 
  'negative is_blacklisted after unblacklist';
# ->get_blacklist
ok $auth->get_blacklist->count == 1,
  '->get_blacklist ArrayObj contains 1 item';
like $auth->get_blacklist->get(0), qr/192.168/,
  '->get_blacklist ArrayObj looks ok';

# ->check for blacklisted addr, good passwd
$ret = $auth->check('192.168.0.4', foo => PASSWD);
ok !$ret->allowed, 'blacklisted addr disallowed (passwd ok)';
like $ret->message, qr/blacklist/,
  'blacklisted addr produced correct message';

# ->whitelist ( FIXME enable whitelist policy ) / ->is_whitelisted
# ->unwhitelist
# ->get_whitelist
# FIXME


# FIXME policy combinations

done_testing
