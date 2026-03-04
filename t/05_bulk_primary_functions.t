use strict;
use warnings;

use Test::More;
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use TrailingStop;
use Manager;

{
    package BulkTestPositions;
    use parent 'Positions';

    sub new_with_responses {
        my ($class, $responses, %args) = @_;
        my $self = $class->SUPER::new(%args);
        $self->{_responses} = $responses;
        $self->{_idx} = 0;
        return $self;
    }

    sub polymarket_cmd_capture {
        my ($self, $needs_wallet, @args) = @_;
        my $r = $self->{_responses}[ $self->{_idx}++ ];
        return @$r;
    }
}

# ---------- TrailingStop primary hog-level checks ----------
# 1) next_stop_price over wide PnL range
for my $pnl (-100 .. 150) {
    my $got = TrailingStop::next_stop_price(
        entry_price   => 1,
        current_stop  => 0.9,
        percent_pnl   => $pnl,
        sl_set_to     => 10,
        ts_trigger_at => 5,
        ts_move_each  => 5,
    );

    my $expected;
    if ($pnl < 5) {
        $expected = 0.9;
    } else {
        my $steps = int((($pnl - 5) / 5)) + 1;
        my $locked_pct = ($steps - 1) * 5;
        $locked_pct = 0 if $locked_pct < 0;
        my $ts_stop = 1 * (1 + $locked_pct / 100);
        $expected = $ts_stop > 0.9 ? $ts_stop : 0.9;
    }

    is(sprintf('%.6f', $got), sprintf('%.6f', $expected), "next_stop_price pnl=$pnl");
}

# 2) evaluate_position wide matrix happy/sad/edge behavior
my @prices = (0.20, 0.35, 0.50, 0.65, 0.80);
my @pnls   = (-50, -25, -10, 0, 5, 10, 15, 25, 50, 75, 100);
for my $price (@prices) {
    for my $pnl (@pnls) {
        my $res = TrailingStop::evaluate_position(
            position => { cur_price => $price, percent_pnl => $pnl },
            state    => {},
            cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
        );

        ok($res->{valid}, "evaluate_position valid price=$price pnl=$pnl");
        ok(defined $res->{stop_price}, "evaluate_position stop exists price=$price pnl=$pnl");
    }
}

for my $bad (
    [{ cur_price => 'x',   percent_pnl => 10 }, 'bad price'],
    [{ cur_price => 0.5,   percent_pnl => 'y' }, 'bad pnl'],
    [{ cur_price => undef, percent_pnl => 10 }, 'undef price'],
) {
    my ($pos, $name) = @$bad;
    my $res = TrailingStop::evaluate_position(
        position => $pos,
        state    => {},
        cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
    );
    ok(!$res->{valid}, "evaluate_position sad path $name");
}

# ---------- Manager helper + queue mechanics ----------
my $m = bless {
    cfg => { result_dir => '/tmp/polyman-bulk-results' },
    state => { positions => {} },
    pending_tasks => [],
    active_workers => {},
}, 'Manager';

# 3) build/enqueue/task-busy/apply result many rounds
for my $i (1..120) {
    my $k = "cond:$i";
    $m->{state}{positions}{$k} = {
        queued   => {},
        tp1_done => JSON::PP::false,
        tp2_done => JSON::PP::false,
    };

    my $task = $m->_build_task(
        action       => 'tp1',
        position_key => $k,
        token_dec    => "$i",
        amount       => '1.00',
    );

    is($task->{action}, 'tp1', "build_task action round=$i");
    is($task->{position_key}, $k, "build_task key round=$i");

    $m->enqueue_task(%$task);
    ok(!$m->_task_is_busy($m->{state}{positions}{$k}, 'tp1'), "not busy before queued mark round=$i");

    $m->{state}{positions}{$k}{queued}{tp1} = JSON::PP::true;
    ok($m->_task_is_busy($m->{state}{positions}{$k}, 'tp1'), "busy after queued mark round=$i");

    $m->_apply_task_result({
        task => { action => 'tp1', position_key => $k },
        ok   => JSON::PP::true,
    });

    ok($m->{state}{positions}{$k}{tp1_done}, "tp1_done set round=$i");
    ok(!$m->{state}{positions}{$k}{queued}{tp1}, "queued cleared round=$i");
}

# 4) duplicate prevention in queue_position_tasks across many positions
$m->{cfg}{tp1_trigger_pct} = 5;
$m->{cfg}{tp1_close_pct} = 10;
$m->{cfg}{tp2_trigger_pct} = 10;
$m->{cfg}{tp2_close_pct} = 20;
$m->{cfg}{max_loss_pct} = 0;
$m->{cfg}{close_on_redeemable} = 0;
$m->{pending_tasks} = [];

for my $i (1..60) {
    my $s = { queued => {}, tp1_done => JSON::PP::false, tp2_done => JSON::PP::false };
    my $p = {
        size        => 10,
        asset_id    => "$i",
        percent_pnl => 25,
        redeemable  => JSON::PP::false,
        condition_id => "c$i",
    };
    my $ts = { stop_hit => 0 };

    $m->_queue_position_tasks($p, $s, "dup:$i", $ts);
    my $before = scalar @{ $m->{pending_tasks} };
    $m->_queue_position_tasks($p, $s, "dup:$i", $ts);
    my $after = scalar @{ $m->{pending_tasks} };

    is($after, $before, "duplicate prevented for dup:$i");
}

# ---------- Positions high-level behavior in bulk ----------
# 5) repeated market_sell/redeem success + failure via stubbed responses
my @responses;
for my $i (1..80) {
    push @responses, [0, '{"status":"ok"}', ''];
    push @responses, [1, '', "sell-fail-$i"];
}
for my $i (1..40) {
    push @responses, [0, '{"redeemed":true}', ''];
    push @responses, [1, '', "redeem-fail-$i"];
}

my $bp = BulkTestPositions->new_with_responses(\@responses);

for my $i (1..80) {
    my $ok = $bp->market_sell(token_dec => "$i", amount => '1');
    ok($ok->{ok}, "bulk market_sell ok $i");

    my $bad = $bp->market_sell(token_dec => "$i", amount => '1');
    ok(!$bad->{ok}, "bulk market_sell fail $i");
}

for my $i (1..40) {
    my $ok = $bp->redeem_condition(condition_id => "c$i");
    ok($ok->{ok}, "bulk redeem ok $i");

    my $bad = $bp->redeem_condition(condition_id => "c$i");
    ok(!$bad->{ok}, "bulk redeem fail $i");
}

done_testing();
