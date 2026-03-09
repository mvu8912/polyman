use strict;
use warnings;

use Test::More;
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

# Deduplicate redeem tasks at condition level (same condition, different position keys/outcomes)
my $m1 = bless {
    state => { positions => {} },
    pending_tasks => [],
    active_workers => {},
}, 'Manager';

$m1->enqueue_task(action => 'redeem', position_key => 'condA:Up', condition_id => 'condA', index_set => 1);
$m1->enqueue_task(action => 'redeem', position_key => 'condA:Down', condition_id => 'condA', index_set => 1);
is(scalar @{ $m1->{pending_tasks} }, 1, 'only one redeem task queued per condition');

# Different index_set under same condition is a different redeem scope.
$m1->enqueue_task(action => 'redeem', position_key => 'condA:Down', condition_id => 'condA', index_set => 2);
is(scalar @{ $m1->{pending_tasks} }, 2, 'different index_set can queue another redeem under same condition');

# If same scope is actively redeeming in a worker, queue should not accept duplicate redeem.
$m1->{active_workers}{777} = {
    task => { action => 'redeem', position_key => 'condC:Up', condition_id => 'condC', index_set => 1 },
    started_at => time,
    baseline => {},
};
$m1->enqueue_task(action => 'redeem', position_key => 'condC:Down', condition_id => 'condC', index_set => 1);
is(scalar @{ $m1->{pending_tasks} }, 2, 'redeem not queued when same redeem scope already active in worker');

ok($m1->_has_active_redeem_worker(), '_has_active_redeem_worker detects active redeem');

done_testing();
