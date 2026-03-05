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
    sub fetch_positions { return shift->{batch} }
}

my $tmpd = tempdir(CLEANUP => 1);
my ($fh, $state_path) = tempfile(DIR => $tmpd);
close $fh;

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

    $m->{positions_api} = MockPositionsAPI->new([
        {
            condition_id => 'c1',
            outcome => 'YES',
            size => '200',
            current_value => '0',
            percent_pnl => '-100',
            redeemable => JSON::PP::true,
        }
    ]);
    $m->run_iteration();
}

is(scalar @{ $m->{pending_tasks} }, 1, 'one task queued');
is($m->{pending_tasks}[0]{action}, 'close_loser', 'redeemable loser is queued for close_loser, not redeem');
is($m->{pending_tasks}[0]{condition_id}, 'c1', 'condition_id passed through for close_loser');


done_testing();
