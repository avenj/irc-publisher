use Test::More;
use strict; use warnings;

use IRC::Publisher::Auth;

my $auth = IRC::Publisher::Auth->new;

# ->policy
is_deeply $auth->policy->unbless, [ -blacklist, -passwd ],
  'default policy: -blacklist, -passwd';

# ->accounts
is_deeply $auth->accounts->keys->unbless, [],
  '->accounts empty by default';
# ->add_account
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
