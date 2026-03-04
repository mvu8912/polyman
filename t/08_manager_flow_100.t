use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile tempdir);
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

{
    package FlowPositionsAPI;
    sub new { bless { batches => $_[1] }, $_[0] }
    sub fetch_positions { return shift->{batches} }
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
    local *Manager::dispatch_workers = sub { }; # keep queue assertions deterministic
    local *Manager::reap_workers = sub { };
    local *Manager::monitor_stalled_workers = sub { };

    for my $i (1..100) {
        my $entry = 0.30 + $i * 0.01;
        my $positions;

        if ($i % 4 == 0) {
            # redeemable flow
            $positions = [{
                condition_id => "c$i",
                outcome => 'YES',
                size => '10',
                asset_id => "$i",
                current_value => '3.00',
                percent_pnl => '2',
                redeemable => JSON::PP::true,
            }];
        }
        elsif ($i % 4 == 1) {
            # zero-value loser flow
            $positions = [{
                condition_id => "c$i",
                outcome => 'YES',
                size => '10',
                asset_id => "$i",
                current_value => '0',
                percent_pnl => '-100',
                redeemable => JSON::PP::false,
            }];
        }
        elsif ($i % 4 == 2) {
            # active trailing flow with stop hit
            $positions = [{
                condition_id => "c$i",
                outcome => 'YES',
                size => '10',
                asset_id => "$i",
                current_value => '5.0',
                percent_pnl => '10',
                cur_price => sprintf('%.6f', $entry * 1.10),
                redeemable => JSON::PP::false,
            }];
            my $key = "c$i:YES";
            $m->{state}{positions}{$key} = {
                queued => {}, tp1_done => JSON::PP::false, tp2_done => JSON::PP::false,
                entry_price => $entry, stop_price => $entry * 1.05,
            };
            $positions->[0]{cur_price} = sprintf('%.6f', $entry * 1.04); # now below stop => hit
            $positions->[0]{percent_pnl} = '4';
        }
        else {
            # active trailing flow no hit
            $positions = [{
                condition_id => "c$i",
                outcome => 'YES',
                size => '10',
                asset_id => "$i",
                current_value => '4.0',
                percent_pnl => '8',
                cur_price => sprintf('%.6f', $entry * 1.08),
                redeemable => JSON::PP::false,
            }];
        }

        $m->{positions_api} = FlowPositionsAPI->new($positions);
        $m->run_iteration();

        my $last = $m->{pending_tasks}[-1];
        if ($i % 4 == 0) {
            is($last->{action}, 'redeem', "flow $i redeemable queues redeem");
        }
        elsif ($i % 4 == 1) {
            is($last->{action}, 'close_loser', "flow $i zero value queues close_loser");
        }
        elsif ($i % 4 == 2) {
            is($last->{action}, 'stop_hit', "flow $i stop hit queues sell/stop_hit");
        }
        else {
            ok(($last->{action} // '') ne 'close_loser', "flow $i positive value not close_loser");
        }
    }
}

done_testing();
