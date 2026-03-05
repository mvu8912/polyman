package Positions;
use strict;
use warnings;

use JSON::PP ();
use Capture::Tiny qw(capture);

sub new {
    my ($class, %args) = @_;
    my $self = {
        signature_type => ($args{signature_type} // ''),
        page_size      => ($args{page_size} // 200),
    };
    return bless $self, $class;
}

sub json_decode {
    my ($self, $txt) = @_;
    my $j = JSON::PP->new->utf8->allow_nonref;
    return $j->decode($txt);
}

sub run_cmd_capture {
    my ($self, @cmd) = @_;
    my ($stdout, $stderr, $exit) = capture { system @cmd };

    if ($exit != 0 && !$stderr && $stdout) {
        $stderr = $stdout;
        $stdout = '';
    }

    return ($exit, $stdout, $stderr);
}

sub polymarket_cmd_capture {
    my ($self, $needs_wallet, @args) = @_;
    my @cmd = ('polymarket');
    if ($needs_wallet && defined $self->{signature_type} && $self->{signature_type} ne '') {
        push @cmd, ('--signature-type', $self->{signature_type});
    }
    push @cmd, @args;
    return $self->run_cmd_capture(@cmd);
}

sub wallet_address {
    my ($self) = @_;
    my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(0, 'wallet', 'address');
    die "Failed polymarket wallet address\n$stderr\n" if $exit != 0;

    $stdout =~ s/^\s+|\s+$//g;
    die "Could not parse wallet address\n" unless $stdout =~ /^0x[0-9a-fA-F]{40}$/;
    return $stdout;
}

sub fetch_positions {
    my ($self, $wallet) = @_;
    my @all;
    my $offset = 0;

    while (1) {
        my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(
            0,
            '-o', 'json', 'data', 'positions', $wallet,
            '--limit', $self->{page_size}, '--offset', $offset,
        );
        die "Failed: polymarket data positions\n$stderr\n" if $exit != 0;

        my $arr = $self->json_decode($stdout);
        die "Expected array from data positions\n" unless ref($arr) eq 'ARRAY';

        last if !@$arr;
        push @all, @$arr;
        last if @$arr < $self->{page_size};
        $offset += $self->{page_size};
    }

    return \@all;
}

sub token_dec_for_position {
    my ($self, $p) = @_;
    return undef unless ref($p) eq 'HASH';

    for my $k (qw(asset_id token_id clob_token_id)) {
        my $v = $p->{$k};
        return $v if defined $v && $v =~ /^\d+$/;
    }

    my $condition_id = $p->{condition_id};
    return undef unless defined $condition_id && $condition_id ne '';

    my $tokens = $self->{market_tokens_cache}{$condition_id};
    if (!defined $tokens) {
        $tokens = eval { $self->_fetch_market_tokens($condition_id) };
        $tokens = [] if $@ || ref($tokens) ne 'ARRAY';
        $self->{market_tokens_cache}{$condition_id} = $tokens;
    }

    my $outcome = $p->{outcome};
    if (defined $outcome && $outcome ne '') {
        my $norm = lc($outcome);
        $norm =~ s/^\s+|\s+$//g;
        for my $t (@$tokens) {
            next unless ref($t) eq 'HASH';
            next unless defined $t->{outcome};
            my $to = lc($t->{outcome});
            $to =~ s/^\s+|\s+$//g;
            my $id = $t->{token_id};
            return $id if $to eq $norm && defined $id && $id =~ /^\d+$/;
        }
    }

    my $idx = $p->{outcome_index};
    if (defined $idx && $idx =~ /^\d+$/) {
        for my $t (@$tokens) {
            next unless ref($t) eq 'HASH';
            my $ti = $t->{outcome_index};
            my $id = $t->{token_id};
            return $id if defined $ti && $ti =~ /^\d+$/ && $ti == $idx && defined $id && $id =~ /^\d+$/;
        }
    }

    return undef;
}

sub _fetch_market_tokens {
    my ($self, $condition_id) = @_;

    my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(
        0,
        '-o', 'json', 'clob', 'market', $condition_id,
    );
    die "Failed: polymarket clob market\n$stderr\n" if $exit != 0;

    my $obj = $self->json_decode($stdout);
    return [] unless ref($obj) eq 'HASH';
    my $tokens = $obj->{tokens};
    return [] unless ref($tokens) eq 'ARRAY';
    return $tokens;
}

sub market_sell {
    my ($self, %args) = @_;
    my $token_dec = $args{token_dec};
    my $amount    = $args{amount};

    my @cmd = (
        '-o', 'json', 'clob', 'market-order',
        '--token', $token_dec, '--side', 'sell', '--amount', $amount,
    );

    my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(1, @cmd);
    return {
        ok    => JSON::PP::false,
        error => $stderr || 'sell failed',
    } if $exit != 0;

    my $resp = eval { $self->json_decode($stdout) };
    $resp = { raw => $stdout } if $@;
    return { ok => JSON::PP::true, response => $resp };
}

sub redeem_condition {
    my ($self, %args) = @_;
    my $condition_id = $args{condition_id};

    my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(
        1,
        '-o', 'json', 'ctf', 'redeem', '--condition', $condition_id,
    );

    return {
        ok    => JSON::PP::false,
        error => $stderr || 'redeem failed',
    } if $exit != 0;

    my $resp = eval { $self->json_decode($stdout) };
    $resp = { raw => $stdout } if $@;
    return { ok => JSON::PP::true, response => $resp };
}

# Best-effort close-out for loser/zero-value positions.
# Order: sell (if possible) -> redeem (if condition available) -> transfer/sweep (if configured).
sub close_zero_value_position {
    my ($self, %args) = @_;

    my $token_dec    = $args{token_dec};
    my $amount       = $args{amount};
    my $condition_id = $args{condition_id};
    my $sweep_to     = $args{sweep_to};

    my @attempts;

    if (defined $token_dec && defined $amount) {
        my $sell = $self->market_sell(token_dec => $token_dec, amount => $amount);
        push @attempts, { action => 'sell', %$sell };
        return { ok => JSON::PP::true, action => 'sell', attempts => \@attempts } if $sell->{ok};
    }

    if (defined $condition_id && $condition_id ne '') {
        my $red = $self->redeem_condition(condition_id => $condition_id);
        push @attempts, { action => 'redeem', %$red };
        return { ok => JSON::PP::true, action => 'redeem', attempts => \@attempts } if $red->{ok};
    }

    if (defined $sweep_to && $sweep_to =~ /^0x[0-9a-fA-F]{40}$/ && defined $token_dec && defined $amount) {
        my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(
            1,
            '-o', 'json', 'ctf', 'transfer', '--token', $token_dec, '--amount', $amount, '--to', $sweep_to,
        );
        if ($exit == 0) {
            push @attempts, { action => 'transfer', ok => JSON::PP::true };
            return { ok => JSON::PP::true, action => 'transfer', attempts => \@attempts };
        }
        push @attempts, { action => 'transfer', ok => JSON::PP::false, error => $stderr || $stdout || 'transfer failed' };
    }

    return {
        ok       => JSON::PP::false,
        action   => 'none',
        error    => 'unable to close zero value position',
        attempts => \@attempts,
    };
}

1;
