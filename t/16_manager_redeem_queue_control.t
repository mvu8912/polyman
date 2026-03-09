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

$m1->enqueue_task(action => 'redeem', position_key => 'condA:Up', condition_id => 'condA');
$m1->enqueue_task(action => 'redeem', position_key => 'condA:Down', condition_id => 'condA');
is(scalar @{ $m1->{pending_tasks} }, 1, 'only one redeem task queued per condition');

# If a condition already has redeem done in state, do not enqueue again.
$m1->{state}{positions}{'condB:Up'} = { done => { redeem => JSON::PP::true } };
$m1->enqueue_task(action => 'redeem', position_key => 'condB:Down', condition_id => 'condB');
is(scalar @{ $m1->{pending_tasks} }, 1, 'redeem not queued when condition already marked done');

# If condition is actively redeeming in a worker, queue should not accept duplicate redeem.
$m1->{active_workers}{777} = {
    task => { action => 'redeem', position_key => 'condC:Up', condition_id => 'condC' },
    started_at => time,
    baseline => {},
};
$m1->enqueue_task(action => 'redeem', position_key => 'condC:Down', condition_id => 'condC');
is(scalar @{ $m1->{pending_tasks} }, 1, 'redeem not queued when condition already active in worker');

ok($m1->_has_active_redeem_worker(), '_has_active_redeem_worker detects active redeem');

done_testing();
