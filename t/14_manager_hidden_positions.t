use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile tempdir);
use lib 't/lib';
use lib 'lib';

use Manager;

{
    package HiddenPositionsAPI;
    sub new { bless { batch => $_[1], calls => 0 }, $_[0] }
    sub fetch_manageable_positions {
        my ($self, $wallet) = @_;
        $self->{calls}++;
        return $self->{batch};
    }
}

my $tmpd = tempdir(CLEANUP => 1);
my ($fh, $state_path) = tempfile(DIR => $tmpd);
close $fh;

my $api = HiddenPositionsAPI->new([
    {
        condition_id => 'c-hidden',
        outcome => 'Yes',
        _hidden => 1,
    }
]);

my $m = bless {
    cfg => {
        state_file => $state_path,
        sl_set_to => 10,
        ts_trigger_at => 5,
        ts_move_each => 5,
        tp1_trigger_pct => 0,
        tp1_close_pct => 0,
        tp2_trigger_pct => 0,
        tp2_close_pct => 0,
        max_loss_pct => 0,
        close_on_redeemable => 1,
        worker_count => 1,
        worker_timeout_s => 30,
        worker_max_retries => 1,
        result_dir => $tmpd,
        loser_sweep_to => '',
    },
    wallet => '0x1111111111111111111111111111111111111111',
    positions_api => $api,
    state => { positions => {} },
    pending_tasks => [],
    active_workers => {},
    last_snapshot => {},
}, 'Manager';

{
    no warnings 'redefine';
    local *Manager::dispatch_workers = sub { };
    local *Manager::reap_workers = sub { };
    local *Manager::monitor_stalled_workers = sub { };

    $m->run_iteration();
}

is($api->{calls}, 1, 'manager prefers fetch_manageable_positions when available');
is(scalar @{ $m->{pending_tasks} }, 1, 'one task queued for hidden position');
is($m->{pending_tasks}[0]{action}, 'redeem', 'hidden position queues redeem task');
is($m->{pending_tasks}[0]{condition_id}, 'c-hidden', 'condition_id forwarded for hidden redeem task');

done_testing();
