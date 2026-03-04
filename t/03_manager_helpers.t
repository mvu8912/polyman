use strict;
use warnings;

use Test::More;
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

my $m = bless {
    cfg => { result_dir => '/tmp/polyman-test-results' },
    state => {
        positions => {
            'cond:yes' => { queued => { tp1 => JSON::PP::true } },
        },
    },
    pending_tasks => [],
    active_workers => {},
}, 'Manager';

is($m->position_key({ condition_id => 'cond', outcome => 'yes' }), 'cond:yes', 'position_key helper');
ok($m->_task_is_busy($m->{state}{positions}{'cond:yes'}, 'tp1'), 'busy helper true');
ok(!$m->_task_is_busy($m->{state}{positions}{'cond:yes'}, 'tp2'), 'busy helper false');

my $task = $m->_build_task(action => 'tp1', position_key => 'cond:yes', token_dec => '123', amount => '1.0');
is($task->{action}, 'tp1', 'build task action');
is($task->{position_key}, 'cond:yes', 'build task key');

$m->enqueue_task(%$task);
is(scalar @{ $m->{pending_tasks} }, 1, 'enqueue_task adds pending task');

my $path = $m->_child_result_path(99999);
like($path, qr{/tmp/polyman-test-results/99999\.json$}, 'child result path helper');

$m->_apply_task_result({
    task => { action => 'tp1', position_key => 'cond:yes' },
    ok   => JSON::PP::true,
});
ok($m->{state}{positions}{'cond:yes'}{tp1_done}, 'apply result marks tp1 done');
ok(!$m->{state}{positions}{'cond:yes'}{queued}{tp1}, 'apply result clears queued flag');

$m->{pending_tasks} = [
    { action => 'tp1', position_key => 'cond:yes' },
];
ok($m->_position_has_inflight_task('cond:yes'), 'inflight helper sees pending task');

$m->{pending_tasks} = [];
$m->{active_workers} = {
    12345 => { task => { action => 'tp2', position_key => 'cond:yes' } },
};
ok($m->_position_has_inflight_task('cond:yes'), 'inflight helper sees active worker task');
ok(!$m->_position_has_inflight_task('cond:no'), 'inflight helper false for other position');

done_testing();
