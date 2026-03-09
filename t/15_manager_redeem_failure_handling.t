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
        $m->_is_permanent_task_failure('redeem', '{"error":"Redeem positions failed"}'),
        'redeem positions failed treated as permanent failure',
    );

    my $task = {
        action => 'redeem',
        position_key => 'c1:Up',
        condition_id => 'c1',
        retries => 0,
    };

    $m->_retry_or_clear($task, '{"error":"Redeem positions failed"}');
}

is(scalar @{ $m->{pending_tasks} }, 0, 'permanent redeem failure is not retried');
ok($m->{state}{positions}{'c1:Up'}{done}{redeem}, 'redeem action marked done after permanent failure');

my $joined = join("\n", @logs);
like($joined, qr/giving up task action=redeem key=c1:Up .*permanent failure/, 'giving-up log emitted for redeem permanent failure');
like($joined, qr/redeem task diagnostic key=c1:Up action=redeem reason=\{"error":"Redeem positions failed"\}/, 'diagnostic redeem log emitted with reason');
like($joined, qr/task=\{/, 'diagnostic log includes serialized task payload');
like($joined, qr/state=\{/, 'diagnostic log includes serialized state payload');

done_testing();
