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
ok !$ret->allowed, 'negative ->check->allowed (bad passwd)';

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
ok !$ret->allowed, 'negative ->check->allowed (after del_account)';

# -blacklist, -passwd policy
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

# -passwd policy
$auth->set_policy([ -passwd ]);
$ret = $auth->check('192.168.0.4', foo => PASSWD);
ok $ret->allowed, 'dropping blacklist policy allowed previously denied addr';

# -whitelist, -passwd policy
$auth->set_policy([ -whitelist, -passwd ]);
$ret = $auth->check('192.168.0.4', foo => PASSWD);
ok !$ret->allowed, 'negative ->check->allowed (good passwd, not whitelisted)';
like $ret->message, qr/whitelist/,
  'non-whitelisted addr produced correct message';
# ->whitelist / ->is_whitelisted
$auth->whitelist('192.168.0.1/16');
$ret = $auth->check('192.168.0.4', foo => PASSWD);
ok $ret->allowed, '->check->allowed (after whitelisting)';

$ret = $auth->check('127.0.0.1', foo => PASSWD);
ok !$ret->allowed, 
  'negative ->check->allowed (after whitelisting other addr)';

$ret = $auth->check('192.168.0.4', foo => 'badpasswd');
ok !$ret->allowed, 'negative ->check->allowed (whitelisted, bad passwd)';

$auth->whitelist('200.201.202.203');
cmp_ok $auth->get_whitelist->count, '==', 2,
  'get_whitelist ArrayObj contains 2 items';
$ret = $auth->check('200.201.202.203', foo => PASSWD);
ok $ret->allowed, 'second addr whitelisted';

# ->unwhitelist
$auth->unwhitelist('200.201.202.203');
$ret = $auth->check('200.201.202.203', foo => PASSWD);
ok !$ret->allowed, 'negative ->check->allowed after unwhitelist';

# ->get_whitelist
cmp_ok $auth->get_whitelist->count, '==', 1,
  'get_whitelist ArrayObj contains 1 item';
like $auth->get_whitelist->get(0), qr/192.168/,
  'get_whitelist Arrayobj looks ok';

# FIXME policy combinations
#  [ -blacklist, -passwd, -whitelist ]
#    * addr not blacklisted, good passwd, whitelisted -> allow
#    * addr not blacklisted, good passwd, not whitelisted  -> deny
#    * addr not blacklisted, bad passwd, whitelisted -> deny

eval {; $auth->set_policy(1) };
like $@, qr/ImmutableArray/, 'set_policy for bad type dies';
eval {; $auth->set_policy([-foo]) };
like $@, qr/known policy/, 'set_policy for unknown policy dies';

done_testing
