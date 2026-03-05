package Positions;
use strict;
use warnings;

use JSON::PP ();
use Capture::Tiny qw(capture);
use Math::BigInt;

my $CTF_ERC1155 = '0x4D97DCd97eC945f40cF65F87097ACe5EA0476045';
my $CHAIN_ID_HEX = '0x89';

sub new {
    my ($class, %args) = @_;
    my $self = {
        signature_type => ($args{signature_type} // ''),
        page_size      => ($args{page_size} // 200),
        private_key    => ($args{private_key} // $ENV{PRIVATE_KEY} // ''),
        wallet_address => ($args{wallet_address} // $ENV{WALLET_ADDRESS} // ''),
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

sub _wallet_env_overrides {
    my ($self) = @_;

    my %env;
    if (defined $self->{private_key} && $self->{private_key} ne '') {
        $env{POLYMARKET_PRIVATE_KEY} = $self->{private_key};
    }
    if (defined $self->{wallet_address} && $self->{wallet_address} ne '') {
        $env{POLYMARKET_WALLET_ADDRESS} = $self->{wallet_address};
    }
    return \%env;
}

sub _run_cmd_with_env {
    my ($self, $env_overrides, @cmd) = @_;
    my $old = {};

    for my $k (keys %$env_overrides) {
        $old->{$k} = exists $ENV{$k} ? $ENV{$k} : undef;
        $ENV{$k} = $env_overrides->{$k};
    }

    my @res = $self->run_cmd_capture(@cmd);

    for my $k (keys %$env_overrides) {
        if (defined $old->{$k}) {
            $ENV{$k} = $old->{$k};
        }
        else {
            delete $ENV{$k};
        }
    }

    return @res;
}

sub polymarket_cmd_capture {
    my ($self, $needs_wallet, @args) = @_;
    my @cmd = ('polymarket');
    if ($needs_wallet && defined $self->{signature_type} && $self->{signature_type} ne '') {
        push @cmd, ('--signature-type', $self->{signature_type});
    }
    push @cmd, @args;

    my $env_overrides = $needs_wallet ? $self->_wallet_env_overrides() : {};
    my ($exit, $stdout, $stderr) = $self->_run_cmd_with_env($env_overrides, @cmd);

    if ($needs_wallet
        && defined($stderr)
        && $stderr =~ /no wallet configured/i
        && defined($self->{private_key})
        && $self->{private_key} ne '') {
        my @retry = ('polymarket');
        push @retry, ('--signature-type', $self->{signature_type})
          if defined $self->{signature_type} && $self->{signature_type} ne '';
        push @retry, ('--private-key', $self->{private_key});
        push @retry, @args;

        my ($x, $o, $e) = $self->_run_cmd_with_env($env_overrides, @retry);
        if ($x == 0) {
            return ($x, $o, $e);
        }

        if (defined $e && $e =~ /unexpected argument '--private-key'|unrecognized option '--private-key'/i) {
            return ($exit, $stdout, $stderr);
        }

        return ($x, $o, $e);
    }

    return ($exit, $stdout, $stderr);
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

    my $condition_id = $p->{condition_id};
    if (defined $condition_id && $condition_id ne '') {
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
                return $id if $to eq $norm && _is_token_id($id);
            }
        }

        my $idx = $p->{outcome_index};
        if (defined $idx && $idx =~ /^\d+$/) {
            for my $t (@$tokens) {
                next unless ref($t) eq 'HASH';
                my $ti = $t->{outcome_index};
                my $id = $t->{token_id};
                return $id if defined $ti && $ti =~ /^\d+$/ && $ti == $idx && _is_token_id($id);
            }
        }

        # Conservative fallback: if only one token exists, use it.
        if (@$tokens == 1 && ref($tokens->[0]) eq 'HASH') {
            my $id = $tokens->[0]{token_id};
            return $id if _is_token_id($id);
        }
    }

    for my $k (qw(clob_token_id asset_id token_id)) {
        my $v = $p->{$k};
        return $v if _is_token_id($v);
    }

    return undef;
}

sub _is_token_id {
    my ($v) = @_;
    return 0 unless defined $v;
    return 1 if $v =~ /^\d+$/;
    return 1 if $v =~ /^0x[0-9a-fA-F]+$/;
    return 0;
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

sub _transfer_outcome_token {
    my ($self, %args) = @_;

    my $token_dec = $args{token_dec};
    my $amount    = $args{amount};
    my $sweep_to  = $args{sweep_to};

    return {
        ok    => JSON::PP::false,
        error => 'missing sweep args',
    } unless defined $sweep_to && $sweep_to =~ /^0x[0-9a-fA-F]{40}$/ && defined $token_dec && defined $amount;

    my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(
        1,
        '-o', 'json', 'ctf', 'transfer', '--token', $token_dec, '--amount', $amount, '--to', $sweep_to,
    );

    return { ok => JSON::PP::true } if $exit == 0;

    my $te = $stderr || $stdout || 'transfer failed';
    if ($te =~ /unrecognized subcommand '\Qtransfer\E'|unrecognized subcommand 'transfer'/i) {
        my $fallback = eval {
            $self->_sweep_transfer_via_raw_tx(
                token_dec => $token_dec,
                amount    => $amount,
                sweep_to  => $sweep_to,
            );
        };

        return {
            ok     => JSON::PP::true,
            txhash => $fallback,
            method => 'raw_tx',
        } if defined $fallback && $fallback ne '';

        my $fallback_err = $@ || '';
        if ($fallback_err ne '') {
            $fallback_err =~ s/\s+\z//;
            return { ok => JSON::PP::false, error => "transfer unsupported by polymarket cli; fallback failed: $fallback_err" };
        }
        $te = 'transfer unsupported by polymarket cli';
    }
    return { ok => JSON::PP::false, error => $te };
}

sub _load_eth_deps {
    require Blockchain::Ethereum::ABI::Encoder;
    require Blockchain::Ethereum::Key;
    require Blockchain::Ethereum::Transaction::Legacy;
}

sub _rpc_call {
    my ($self, $method, $params) = @_;

    my $rpc = $ENV{RPC_URL} // '';
    die "RPC_URL missing for raw transfer fallback\n" unless $rpc ne '';

    my $payload = JSON::PP::encode_json({
        jsonrpc => '2.0',
        id      => 1,
        method  => $method,
        params  => $params,
    });

    my ($exit, $stdout, $stderr) = $self->run_cmd_capture(
        'curl', '-sS', '-H', 'Content-Type: application/json', '--data', $payload, $rpc,
    );
    die "RPC call failed: $method\n$stderr\n" if $exit != 0;

    my $obj = eval { JSON::PP::decode_json($stdout) };
    die "RPC decode failed: $method\n$stdout\n" if $@ || ref($obj) ne 'HASH';
    die "RPC error: $method\n" . JSON::PP::encode_json($obj->{error}) . "\n" if exists $obj->{error} && defined $obj->{error};
    return $obj->{result};
}

sub _hex_to_bigint {
    my ($hex) = @_;
    $hex //= '0x0';
    $hex =~ s/^0x//i;
    return Math::BigInt->from_hex('0x' . ($hex eq '' ? '0' : $hex));
}

sub _bigint_to_hex {
    my ($bi) = @_;
    my $h = $bi->copy->as_hex();
    $h =~ s/^\+//;
    $h = lc($h);
    return $h;
}

sub _token_id_to_hex {
    my ($self, $token_dec) = @_;
    return $token_dec if defined $token_dec && $token_dec =~ /^0x[0-9a-fA-F]+$/;

    my $bi = Math::BigInt->new("$token_dec");
    die "invalid token id: $token_dec\n" if !defined $bi;
    return _bigint_to_hex($bi);
}

sub _sweep_transfer_via_raw_tx {
    my ($self, %args) = @_;
    _load_eth_deps();

    my $token_hex = $self->_token_id_to_hex($args{token_dec});
    my $amount    = $args{amount};
    my $sweep_to  = $args{sweep_to};

    my $pk = $self->{private_key} // '';
    $pk =~ s/^0x//i;
    die "private key missing for raw transfer fallback\n" unless $pk =~ /^[0-9a-fA-F]{64}$/;

    my $from = $self->{wallet_address} // '';
    die "wallet address missing for raw transfer fallback\n" unless $from =~ /^0x[0-9a-fA-F]{40}$/;

    my $key = Blockchain::Ethereum::Key->new(private_key => pack('H*', $pk));
    my $derived_from = '' . $key->address;
    die "wallet address does not match private key ($derived_from)\n" unless lc($derived_from) eq lc($from);

    my $token_dec_str = _hex_to_bigint($token_hex)->bstr();
    my $enc = Blockchain::Ethereum::ABI::Encoder->new;
    my $data = $enc->function('safeTransferFrom')
      ->append(address => $from)
      ->append(address => $sweep_to)
      ->append(uint256 => $token_dec_str)
      ->append(uint256 => "$amount")
      ->append(bytes   => '00')
      ->encode();

    my $nonce = $self->_rpc_call('eth_getTransactionCount', [$from, 'pending']);
    my $gas_price = $self->_rpc_call('eth_gasPrice', []);
    my $estimate = $self->_rpc_call('eth_estimateGas', [{
        from  => $from,
        to    => $CTF_ERC1155,
        value => '0x0',
        data  => $data,
    }]);

    my $gas_limit_bi = _hex_to_bigint($estimate);
    $gas_limit_bi->bmul(125);
    $gas_limit_bi->bdiv(100);
    my $gas_limit = _bigint_to_hex($gas_limit_bi);

    my $tx = Blockchain::Ethereum::Transaction::Legacy->new(
        nonce     => $nonce,
        gas_price => $gas_price,
        gas_limit => $gas_limit,
        to        => $CTF_ERC1155,
        value     => '0x0',
        data      => $data,
        chain_id  => $CHAIN_ID_HEX,
    );
    $key->sign_transaction($tx);

    my $raw = $tx->serialize;
    $raw =~ s/^\s+|\s+$//g;
    if ($raw !~ /^0x[0-9a-fA-F]+$/) {
        my $hex = unpack('H*', $raw);
        $raw = '0x' . $hex;
    }

    return $self->_rpc_call('eth_sendRawTransaction', [$raw]);
}

# Best-effort close-out for loser/zero-value positions.
# Order: sell (if possible) -> redeem (if condition available) -> transfer/sweep (if configured).
sub close_zero_value_position {
    my ($self, %args) = @_;

    my $token_dec    = $args{token_dec};
    my $amount       = $args{amount};
    my $condition_id = $args{condition_id};
    my $sweep_to     = $args{sweep_to};
    my $prefer_sweep = $args{prefer_sweep} ? 1 : 0;

    my @attempts;

    if ($prefer_sweep && defined $sweep_to && $sweep_to =~ /^0x[0-9a-fA-F]{40}$/ && defined $token_dec && defined $amount) {
        my $xfer = $self->_transfer_outcome_token(token_dec => $token_dec, amount => $amount, sweep_to => $sweep_to);
        push @attempts, { action => 'transfer', %$xfer };
        return { ok => JSON::PP::true, action => 'transfer', attempts => \@attempts } if $xfer->{ok};
    }

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
        my $xfer = $self->_transfer_outcome_token(token_dec => $token_dec, amount => $amount, sweep_to => $sweep_to);
        push @attempts, { action => 'transfer', %$xfer };
        return { ok => JSON::PP::true, action => 'transfer', attempts => \@attempts } if $xfer->{ok};
    }

    return {
        ok       => JSON::PP::false,
        action   => 'none',
        error    => 'unable to close zero value position',
        attempts => \@attempts,
    };
}


1;
