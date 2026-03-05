use strict;
use warnings;

use Test::More;

use lib 'lib';
use Manager;

{
    package MockPositionsNoWallet;
    sub new { bless { fetch_calls => 0 }, shift }
    sub wallet_address { die "Failed polymarket wallet address\nNo wallet configured\n"; }
    sub fetch_positions {
        my ($self) = @_;
        $self->{fetch_calls}++;
        return [];
    }
}

my $m = bless {
    cfg => {
        state_file => '/tmp/polyman-state-test.json',
        result_dir => '/tmp',
        worker_count => 1,
        worker_timeout_s => 60,
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
    state => { positions => {} },
    pending_tasks => [],
    active_workers => {},
    last_snapshot => {},
    positions_api => MockPositionsNoWallet->new,
}, 'Manager';

my $ok = eval { $m->run_iteration(); 1 };
ok($ok, 'run_iteration does not die when wallet is unavailable');
is($m->{positions_api}{fetch_calls}, 0, 'run_iteration skips fetch_positions without wallet');

$m->{wallet} = '0x1111111111111111111111111111111111111111';
$ok = eval { $m->run_iteration(); 1 };
ok($ok, 'run_iteration succeeds when wallet is preconfigured');
is($m->{positions_api}{fetch_calls}, 1, 'run_iteration fetches positions after wallet is set');

done_testing();
