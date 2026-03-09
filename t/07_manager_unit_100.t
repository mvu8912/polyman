use strict;
use warnings;

use Test::More;
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

my $m = bless {
    cfg => {
        worker_timeout_s   => 1,
        worker_max_retries => 2,
    },
    state => { positions => {} },
    pending_tasks => [],
    active_workers => {},
}, 'Manager';

# 1..100 unit-level assertions focused on helper behavior
for my $i (1..50) {
    my $task = { action => 'stop_hit', position_key => "k$i", retries => 0 };
    my $before = { "k$i" => { size => 10, current_value => 5, redeemable => 0 } };
    my $after_progress = { "k$i" => { size => 9, current_value => 4, redeemable => 0 } };
    my $after_none = { "k$i" => { size => 10, current_value => 5, redeemable => 0 } };

    ok($m->_task_has_progress($task, $before, $after_progress), "unit progress detected round $i");
    ok(!$m->_task_has_progress($task, $before, $after_none), "unit no progress round $i");
}

my $missing_task = { action => 'stop_hit', position_key => 'missing:1', retries => 0 };
my $missing_before = { 'missing:1' => { size => 10, current_value => 5, redeemable => 0 } };
my $missing_after = {};
ok(!$m->_task_has_progress($missing_task, $missing_before, $missing_after), 'missing snapshot key is not treated as progress');

for my $i (1..25) {
    my $key = "r$i";
    $m->{state}{positions}{$key} = { queued => { stop_hit => JSON::PP::true } };
    my $task = { action => 'stop_hit', position_key => $key, retries => 0 };

    $m->_retry_or_clear($task, 'unit-test');
    ok(scalar(@{ $m->{pending_tasks} }) >= 1, "retry enqueued round $i");

    my $last = $m->{pending_tasks}[-1];
    is($last->{position_key}, $key, "retry key round $i");
}

# stalled worker unit checks with fake pid and no progress
my $st = bless {
    cfg => { worker_timeout_s => 0, worker_max_retries => 1 },
    state => { positions => { 'stall:1' => { queued => { stop_hit => JSON::PP::true } } } },
    pending_tasks => [],
    active_workers => {
        999999 => {
            task => { action => 'stop_hit', position_key => 'stall:1', retries => 0 },
            started_at => time - 10,
            baseline => { 'stall:1' => { size => 10, current_value => 5 } },
        }
    },
}, 'Manager';

# timeout disabled => should not touch
$st->monitor_stalled_workers({ 'stall:1' => { size => 10, current_value => 5 } });
is(scalar(keys %{ $st->{active_workers} }), 1, 'no monitoring when timeout disabled');

$st->{cfg}{worker_timeout_s} = 1;
$st->monitor_stalled_workers({ 'stall:1' => { size => 10, current_value => 5 } });
ok(!exists $st->{active_workers}{999999}, 'stalled worker removed from active map');
ok(scalar(@{ $st->{pending_tasks} }) >= 1, 'stalled worker task requeued');

# ensure duplicate enqueue prevention works for same task signature
my $dup = bless {
    cfg => {},
    pending_tasks => [],
}, 'Manager';

for my $i (1..23) {
    $dup->enqueue_task(action => 'redeem', position_key => 'same:key', condition_id => 'c1');
    $dup->enqueue_task(action => 'redeem', position_key => 'same:key', condition_id => 'c1');
    is(scalar(@{ $dup->{pending_tasks} }), 1, "duplicate enqueue blocked round $i");
}



# close_loser busy should suppress queueing other sell tasks
my $busy_close = bless {
    cfg => {
        tp1_trigger_pct => 1,
        tp1_close_pct => 50,
        tp2_trigger_pct => 0,
        tp2_close_pct => 0,
        max_loss_pct => 0,
    },
    pending_tasks => [],
    active_workers => {},
}, 'Manager';
my $state_busy = { queued => { close_loser => JSON::PP::true }, done => {} };
$busy_close->_queue_position_tasks(
    { size => '10', percent_pnl => '10', token_id => '123' },
    $state_busy,
    'busy:key',
    { stop_hit => 1 },
);
is(scalar @{ $busy_close->{pending_tasks} }, 0, 'no tp/stop tasks queued while close_loser is busy');



# redeem verification should not treat size=0/current_value=0 as clear when still redeemable
my $redeem_task = { action => 'redeem', position_key => 'condR:Up', retries => 0 };
ok(
    !$m->_task_position_gone([
        { condition_id => 'condR', outcome => 'Up', size => 0, current_value => 0, redeemable => JSON::PP::true }
    ], $redeem_task),
    'redeem verify keeps waiting while position remains redeemable',
);
ok(
    $m->_task_position_gone([
        { condition_id => 'condR', outcome => 'Up', size => 0, current_value => 0, redeemable => JSON::PP::false }
    ], $redeem_task),
    'redeem verify succeeds once position is no longer redeemable',
);

done_testing();
