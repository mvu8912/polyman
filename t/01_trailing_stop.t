use strict;
use warnings;

use Test::More;
use lib 'lib';

use TrailingStop;

is(sprintf('%.6f', TrailingStop::calc_entry_price(cur_price => 0.55, percent_pnl => 10)), '0.500000', 'calc_entry_price happy path');
ok(!defined TrailingStop::calc_entry_price(cur_price => 'x', percent_pnl => 10), 'calc_entry_price invalid input');

is(sprintf('%.4f', TrailingStop::next_stop_price(entry_price => 1, current_stop => undef, percent_pnl => 0, sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5)), '0.9000', 'baseline stop set');
is(sprintf('%.4f', TrailingStop::next_stop_price(entry_price => 1, current_stop => 0.9, percent_pnl => 5, sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5)), '1.0000', '5% profit moves SL to entry');
is(sprintf('%.4f', TrailingStop::next_stop_price(entry_price => 1, current_stop => 1.0, percent_pnl => 10, sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5)), '1.0500', '10% profit moves SL to 5%');

ok(TrailingStop::should_sell_on_stop(cur_price => 0.9, stop_price => 0.9), 'sell on stop at exact price');
ok(!TrailingStop::should_sell_on_stop(cur_price => 0.91, stop_price => 0.9), 'no sell above stop');

my $invalid = TrailingStop::evaluate_position(
    position => { cur_price => 'bad', percent_pnl => 5 },
    state    => {},
    cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
);
ok(!$invalid->{valid}, 'sad path invalid evaluate_position');

my $res1 = TrailingStop::evaluate_position(
    position => { cur_price => 0.60, percent_pnl => 15 },
    state    => {},
    cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
);
ok($res1->{valid}, 'evaluate_position valid');
ok($res1->{moved}, 'evaluate_position moved stop');
ok(!$res1->{stop_hit}, 'edge case no stop hit while above stop');

my $res2 = TrailingStop::evaluate_position(
    position => { cur_price => 0.40, percent_pnl => -20 },
    state    => { entry_price => 0.50, stop_price => 0.45 },
    cfg      => { sl_set_to => 10, ts_trigger_at => 5, ts_move_each => 5 },
);
ok($res2->{stop_hit}, 'stop hit detected');
is(sprintf('%.4f', $res2->{stop_price}), '0.4500', 'stop does not move down');

done_testing();
