use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile tempdir);
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

{
    package MockPositionsAPI;
    sub new { bless { batch => $_[1] }, $_[0] }
    sub fetch_manageable_positions { return shift->{batch} }
}

my $tmpd = tempdir(CLEANUP => 1);
my ($fh, $state_path) = tempfile(DIR => $tmpd);
close $fh;

my $m = bless {
    cfg => {
        state_file => $state_path,
        close_on_redeemable => 1,
        redeem_retry_cooldown_s => 300,
        sl_set_to => 10,
        ts_trigger_at => 5,
        ts_move_each => 5,
        tp1_trigger_pct => 0,
        tp1_close_pct => 0,
        tp2_trigger_pct => 0,
        tp2_close_pct => 0,
        max_loss_pct => 0,
        worker_count => 1,
        worker_timeout_s => 30,
        worker_max_retries => 1,
        result_dir => $tmpd,
        loser_sweep_to => '',
    },
    wallet => '0x1111111111111111111111111111111111111111',
    state => {
        positions => {
            'c1:Up' => {
                done => { redeem => JSON::PP::true },
                failed => { redeem_at => time() },
                queued => {},
            }
        }
    },
    pending_tasks => [],
    active_workers => {},
    last_snapshot => {},
}, 'Manager';

$m->{positions_api} = MockPositionsAPI->new([
    {
        condition_id => 'c1',
        outcome => 'Up',
        outcome_index => 0,
        redeemable => JSON::PP::true,
        size => '0.2',
        current_value => '0.22',
    }
]);

{
    no warnings 'redefine';
    local *Manager::dispatch_workers = sub { };
    local *Manager::reap_workers = sub { };
    local *Manager::monitor_stalled_workers = sub { };

    $m->run_iteration();
}

ok(!($m->{state}{positions}{'c1:Up'}{done}{redeem}), 'stale done.redeem cleared when position still redeemable');
is(scalar @{ $m->{pending_tasks} }, 0, 'no redeem queued during cooldown window');

# expire cooldown and retry
$m->{state}{positions}{'c1:Up'}{failed}{redeem_at} = time() - 3600;
$m->{pending_tasks} = [];

{
    no warnings 'redefine';
    local *Manager::dispatch_workers = sub { };
    local *Manager::reap_workers = sub { };
    local *Manager::monitor_stalled_workers = sub { };

    $m->run_iteration();
}

is(scalar @{ $m->{pending_tasks} }, 1, 'redeem queued again after cooldown expires');
is($m->{pending_tasks}[0]{action}, 'redeem', 'queued action is redeem');

done_testing();
