use strict;
use warnings;

use Test::More;
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

my @logs;
my $m = bless {
    cfg => { worker_max_retries => 3 },
    state => {
        positions => {
            'c1:Up' => {
                queued => { redeem => JSON::PP::true },
                done => {},
                last_position => { condition_id => 'c1', outcome => 'Up', size => '1.23' },
            }
        }
    },
    pending_tasks => [],
}, 'Manager';

{
    no warnings 'redefine';
    local *Manager::log_line = sub {
        my ($self, $msg) = @_;
        push @logs, $msg;
    };

    ok(
        !$m->_is_permanent_task_failure('redeem', '{"error":"Redeem positions failed"}'),
        'redeem positions failed treated as retryable failure',
    );

    my $task = {
        action => 'redeem',
        position_key => 'c1:Up',
        condition_id => 'c1',
        retries => 0,
    };

    $m->_retry_or_clear($task, '{"error":"Redeem positions failed"}');
}

is(scalar @{ $m->{pending_tasks} }, 1, 'retryable redeem failure is queued for retry');
is($m->{pending_tasks}[0]{action}, 'redeem', 'queued retry action is redeem');
is($m->{pending_tasks}[0]{retries}, 1, 'queued retry increments retry counter');
ok(!($m->{state}{positions}{'c1:Up'}{done}{redeem}), 'redeem action is not marked done after failure');
ok(!($m->{state}{positions}{'c1:Up'}{failed}{redeem_at}), 'redeem failure timestamp not recorded until retries are exhausted');

my $joined = join("\n", @logs);
unlike($joined, qr/giving up task action=redeem key=c1:Up/, 'no giving-up log emitted while redeem is still retryable');
like($joined, qr/task diagnostic action=redeem key=c1:Up mode=retrying reason=\{"error":"Redeem positions failed"\}/, 'diagnostic redeem log emitted in retrying mode');
like($joined, qr/retry task action=redeem key=c1:Up retry=1 reason=\{"error":"Redeem positions failed"\}/, 'retry log emitted for redeem failure');
like($joined, qr/task=\{/, 'diagnostic log includes serialized task payload');
like($joined, qr/position=\{"condition_id":"c1","outcome":"Up","size":"1\.23"\}/, 'diagnostic log includes serialized position payload');
like($joined, qr/state=\{/, 'diagnostic log includes serialized state payload');

done_testing();
