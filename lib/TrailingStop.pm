package TrailingStop;
use strict;
use warnings;

use POSIX qw(floor);

sub calc_entry_price {
    my (%args) = @_;
    my $cur_price   = $args{cur_price};
    my $percent_pnl = $args{percent_pnl};

    return undef unless defined $cur_price && defined $percent_pnl;
    return undef unless $cur_price =~ /^-?\d+(?:\.\d+)?$/;
    return undef unless $percent_pnl =~ /^-?\d+(?:\.\d+)?$/;

    my $den = 1 + (($percent_pnl + 0) / 100);
    return undef if $den <= 0;
    return ($cur_price + 0) / $den;
}

sub next_stop_price {
    my (%args) = @_;
    my $entry_price   = $args{entry_price};
    my $current_stop  = $args{current_stop};
    my $percent_pnl   = $args{percent_pnl};
    my $sl_set_to     = $args{sl_set_to};
    my $ts_trigger_at = $args{ts_trigger_at};
    my $ts_move_each  = $args{ts_move_each};

    return undef unless defined $entry_price;

    my $baseline = $entry_price * (1 - (($sl_set_to + 0) / 100));
    my $stop = defined($current_stop) ? $current_stop : $baseline;

    return $stop if ($ts_move_each + 0) <= 0;
    return $stop if ($percent_pnl + 0) < ($ts_trigger_at + 0);

    my $steps = floor((($percent_pnl + 0) - ($ts_trigger_at + 0)) / ($ts_move_each + 0)) + 1;
    $steps = 0 if $steps < 0;

    my $locked_pct = ($steps - 1) * ($ts_move_each + 0);
    $locked_pct = 0 if $locked_pct < 0;

    my $ts_stop = $entry_price * (1 + ($locked_pct / 100));
    return $ts_stop > $stop ? $ts_stop : $stop;
}

sub should_sell_on_stop {
    my (%args) = @_;
    my $cur_price  = $args{cur_price};
    my $stop_price = $args{stop_price};

    return 0 unless defined $cur_price && defined $stop_price;
    return ($cur_price + 0) <= ($stop_price + 0) ? 1 : 0;
}

sub evaluate_position {
    my (%args) = @_;
    my $position = $args{position} || {};
    my $state    = $args{state}    || {};
    my $cfg      = $args{cfg}      || {};

    my $cur_price   = $position->{cur_price};
    my $percent_pnl = $position->{percent_pnl};

    my $entry = $state->{entry_price};
    if (!defined $entry) {
        $entry = calc_entry_price(cur_price => $cur_price, percent_pnl => $percent_pnl);
        return { valid => 0, reason => 'cannot-calc-entry' } unless defined $entry;
        $state->{entry_price} = $entry + 0;
    }

    my $new_stop = next_stop_price(
        entry_price   => $state->{entry_price},
        current_stop  => $state->{stop_price},
        percent_pnl   => $percent_pnl,
        sl_set_to     => $cfg->{sl_set_to},
        ts_trigger_at => $cfg->{ts_trigger_at},
        ts_move_each  => $cfg->{ts_move_each},
    );

    my $moved = 0;
    if (!defined($state->{stop_price}) || (defined($new_stop) && $new_stop > $state->{stop_price})) {
        $state->{stop_price} = $new_stop;
        $moved = 1;
    }

    my $stop_hit = should_sell_on_stop(cur_price => $cur_price, stop_price => $state->{stop_price});

    return {
        valid      => 1,
        state      => $state,
        moved      => $moved,
        stop_price => $state->{stop_price},
        stop_hit   => $stop_hit,
    };
}

1;
