use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

my $tmp = tempdir(CLEANUP => 1);
my $state_file = "$tmp/state.json";

my $key = 'cond:yes';

{
    package MockPositionsAPI;
    sub fetch_positions { return []; }
}

my $m = bless {
    cfg => {
        state_file => $state_file,
        result_dir => $tmp,
        worker_count => 1,
        worker_timeout_s => 3600,
        worker_max_retries => 1,
        close_on_redeemable => 0,
        max_loss_pct => 0,
        sl_set_to => 10,
        ts_trigger_at => 5,
        ts_move_each => 5,
        tp1_trigger_pct => 0,
        tp1_close_pct => 0,
        tp2_trigger_pct => 0,
        tp2_close_pct => 0,
    },
    state => {
        positions => {
            $key => {
                queued => { stop_hit => JSON::PP::true },
                tp1_done => JSON::PP::false,
                tp2_done => JSON::PP::false,
            },
        },
    },
    pending_tasks => [],
    active_workers => {
        999999 => {
            task => { action => 'stop_hit', position_key => $key },
            started_at => time(),
            baseline => {},
        },
    },
    last_snapshot => {},
    positions_api => bless({}, 'MockPositionsAPI'),
}, 'Manager';

$m->run_iteration();

ok(exists $m->{state}{positions}{$key}, 'run_iteration keeps unseen position state with inflight task');

done_testing();
