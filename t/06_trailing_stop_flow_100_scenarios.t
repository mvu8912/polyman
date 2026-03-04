use strict;
use warnings;

use Test::More;
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use TrailingStop;
use Manager;

my $manager = bless {
    cfg => {
        tp1_trigger_pct => 0,
        tp1_close_pct => 0,
        tp2_trigger_pct => 0,
        tp2_close_pct => 0,
        max_loss_pct => 0,
        close_on_redeemable => 0,
    },
    pending_tasks => [],
}, 'Manager';

for my $scenario (1..100) {
    my $entry = 0.20 + ($scenario * 0.01);
    my $state = { queued => {}, tp1_done => JSON::PP::false, tp2_done => JSON::PP::false, entry_price => $entry };

    # Step 1: initial below trigger -> baseline stop (10% below entry)
    my $s1 = TrailingStop::evaluate_position(
        position => { cur_price => sprintf('%.6f', $entry * 0.97), percent_pnl => -3 },
        state    => $state,
        cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
    );
    ok($s1->{valid}, "scenario $scenario step1 valid");
    is(sprintf('%.6f', $s1->{stop_price}), sprintf('%.6f', $entry * 0.90), "scenario $scenario initial baseline stop");

    # Step 2: initial trigger at +5% -> move SL to entry
    my $s2 = TrailingStop::evaluate_position(
        position => { cur_price => sprintf('%.6f', $entry * 1.05), percent_pnl => 5 },
        state    => $state,
        cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
    );
    ok($s2->{valid}, "scenario $scenario step2 valid");
    is(sprintf('%.6f', $s2->{stop_price}), sprintf('%.6f', $entry), "scenario $scenario trigger moves SL to entry");

    # Step 3: reaches +10% -> move SL to +5%
    my $s3 = TrailingStop::evaluate_position(
        position => { cur_price => sprintf('%.6f', $entry * 1.10), percent_pnl => 10 },
        state    => $state,
        cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
    );
    ok($s3->{valid}, "scenario $scenario step3 valid");
    is(sprintf('%.6f', $s3->{stop_price}), sprintf('%.6f', $entry * 1.05), "scenario $scenario +10% moves SL to +5%");

    # Step 4: price comes down; odd scenarios hit stop, even scenarios don't
    my $fall_price = ($scenario % 2)
      ? ($entry * 1.04)  # hit (below 1.05)
      : ($entry * 1.06); # no hit

    my $s4 = TrailingStop::evaluate_position(
        position => { cur_price => sprintf('%.6f', $fall_price), percent_pnl => (($fall_price / $entry - 1) * 100) },
        state    => $state,
        cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
    );

    if ($scenario % 2) {
        ok($s4->{stop_hit}, "scenario $scenario fall hits stop");

        # Manager action for stop-hit should be sell task ('stop_hit') and not duplicate.
        my $before = scalar @{ $manager->{pending_tasks} };
        $manager->_queue_position_tasks(
            { size => 10, asset_id => "$scenario", percent_pnl => 4, redeemable => JSON::PP::false, condition_id => "c$scenario" },
            $state,
            "k$scenario",
            { stop_hit => 1 },
        );
        my $after = scalar @{ $manager->{pending_tasks} };
        is($after, $before + 1, "scenario $scenario queue adds sell task on stop hit");
        is($manager->{pending_tasks}[-1]{action}, 'stop_hit', "scenario $scenario action is stop_hit (sell path)");

        my $after_once = scalar @{ $manager->{pending_tasks} };
        $manager->_queue_position_tasks(
            { size => 10, asset_id => "$scenario", percent_pnl => 4, redeemable => JSON::PP::false, condition_id => "c$scenario" },
            $state,
            "k$scenario",
            { stop_hit => 1 },
        );
        is(scalar(@{ $manager->{pending_tasks} }), $after_once, "scenario $scenario duplicate stop-hit task prevented");
    }
    else {
        ok(!$s4->{stop_hit}, "scenario $scenario fall does not hit stop");
    }
}

done_testing();
