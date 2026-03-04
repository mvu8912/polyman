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

done_testing();
