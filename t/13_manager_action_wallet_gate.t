use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile tempdir);
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

{
    package MockPositionsWalletMissing;
    sub new { bless { batch => $_[1], fetch_calls => 0 }, $_[0] }
    sub wallet_address { die "Failed polymarket wallet address\nNo wallet configured\n"; }
    sub fetch_positions {
        my ($self) = @_;
        $self->{fetch_calls}++;
        return $self->{batch};
    }
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

    $m->{positions_api} = MockPositionsWalletMissing->new([
        {
            condition_id => 'c1',
            outcome => 'YES',
            size => '10',
            asset_id => '123',
            current_value => '0',
            percent_pnl => '-100',
            redeemable => JSON::PP::true,
        }
    ]);

    $m->run_iteration();
}

is($m->{positions_api}{fetch_calls}, 1, 'still fetches positions with env wallet');
is(scalar @{ $m->{pending_tasks} }, 0, 'no close/redeem actions queued when action wallet is unavailable');

ok(exists $m->{state}{positions}{'c1:YES'}, 'position state is still tracked');


done_testing();
