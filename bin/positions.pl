#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use JSON::PP     ();
use Capture::Tiny qw(capture);
use POSIX        qw(strftime);

# Polymarket Polygon mainnet CTF ERC1155
my $CTF_ERC1155  = '0x4D97DCd97eC945f40cF65F87097ACe5EA0476045';
my $CHAIN_ID_HEX = '0x89';                                         # 137

my %opt = (
    output    => 'table',    # table|json
    address   => undef,      # default: polymarket wallet address
    page_size => 200,

    # manual sell
    sell  => undef,          # optional string; if present but empty => sell all
    limit => undef,          # optional limit price (create-order)

    # auto close
    close          => 0,
    signature_type => undef,    # passed to polymarket for wallet actions

    # sweep config
    sweep_to       => undef,  # if set, sweep dead tokens out (ERC1155 transfer)
    sweep_losers   => 1,      # sweep redeemable losers
    sweep_zombie   => 1,      # sweep non-sellable / no orderbook
    sweep_illiquid =>
      0,    # sweep "no market price" cases too (disabled by default)
    illiquid_max_value => 0.10
    , # only sweep illiquid if current_value <= this (if sweep_illiquid enabled)

    # onchain display
    with_onchain => 0,
    hide_cleared => 0,

    # tx settings for sweep
    dry_run     => 0,
    rpc         => $ENV{RPC_URL},
    private_key => $ENV{PRIVATE_KEY},
    min_gwei    => 25,
    max_actions => 0,

    verbose => 0,
    help    => 0,
);

GetOptions(
    'output=s'    => \$opt{output},
    'address=s'   => \$opt{address},
    'page-size=i' => \$opt{page_size},

    'sell:s'  => \$opt{sell},
    'limit=f' => \$opt{limit},

    'close!'           => \$opt{close},
    'signature-type=s' => \$opt{signature_type},

    'sweep-to=s'           => \$opt{sweep_to},
    'sweep-losers!'        => \$opt{sweep_losers},
    'sweep-zombie!'        => \$opt{sweep_zombie},
    'sweep-illiquid!'      => \$opt{sweep_illiquid},
    'illiquid-max-value=f' => \$opt{illiquid_max_value},

    'with-onchain!' => \$opt{with_onchain},
    'hide-cleared!' => \$opt{hide_cleared},

    'dry-run!'      => \$opt{dry_run},
    'rpc=s'         => \$opt{rpc},
    'private-key=s' => \$opt{private_key},
    'min-gwei=i'    => \$opt{min_gwei},
    'max-actions=i' => \$opt{max_actions},

    'verbose!' => \$opt{verbose},
    'help'     => \$opt{help},
) or die "Bad args. Try --help\n";

if ( $opt{help} ) {
    print <<"HELP";
Usage:
  perl positions.pl
  perl positions.pl --output json

Manual sell (mixed ids allowed):
  perl positions.pl --sell 0xbb...conditionid...
  perl positions.pl --sell 0x....clobtokenhex...
  perl positions.pl --sell 123....clobtokendec...
  perl positions.pl --sell 0xbb...,0x...,123...

Sell everything you currently hold:
  perl positions.pl --sell

Auto close:
  perl positions.pl --close --signature-type proxy

Auto close + sweep losers/zombies to a junk wallet:
  perl positions.pl --close --signature-type proxy \\
    --sweep-to 0xYourWallet \\
    --rpc \$RPC_URL --private-key \$PRIVATE_KEY

Show on-chain balances:
  perl positions.pl --with-onchain --rpc \$RPC_URL

Hide cleared (on-chain balance == 0):
  perl positions.pl --with-onchain --hide-cleared --rpc \$RPC_URL

Notes:
  - Sweeping needs: cpanm Blockchain::Ethereum
  - Sweeping requires POL for gas.
HELP
    exit 0;
}

$opt{output} = lc( $opt{output} // 'table' );
die "--output must be table|json\n"
  unless $opt{output} eq 'table' || $opt{output} eq 'json';

sub trim {
    my ($s) = @_;
    return $s if ref $s;
    $s //= '';
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

sub json_decode {
    my ($txt) = @_;
    my $j = JSON::PP->new->utf8->allow_nonref;
    return $j->decode($txt);
}

sub json_encode_pretty {
    my ($data) = @_;
    my $j = JSON::PP->new->utf8->canonical->pretty;
    return $j->encode($data);
}

sub run_cmd_capture {
    my (@cmd) = @_;

    my ($stdout, $stderr, $exit) = capture { system @cmd };

    # some tools print errors to stdout
    if ( $exit != 0 && !$stderr && $stdout ) {
        $stderr = $stdout;
        $stdout = '';
    }

    print "CMD>> " . join( ' ', @cmd ) . "\n" if $ENV{DEBUG};

    return ( $exit, $stdout, $stderr );
}

sub polymarket_cmd_capture {
    my ( $needs_wallet, @args ) = @_;
    my @cmd = ('polymarket');
    if (   $needs_wallet
        && defined $opt{signature_type}
        && length $opt{signature_type} )
    {
        push @cmd, ( '--signature-type', $opt{signature_type} );
    }
    push @cmd, @args;
    return run_cmd_capture(@cmd);
}

sub get_wallet_address_from_cli {
    my ( $exit, $stdout, $stderr ) =
      polymarket_cmd_capture( 0, 'wallet', 'address' );
    die "Failed: polymarket wallet address\n$stderr\n" if $exit != 0;
    my $w = trim($stdout);
    die "Could not parse wallet address\n" unless $w =~ /^0x[0-9a-fA-F]{40}$/;
    return $w;
}

sub fetch_all_positions {
    my ( $wallet, $limit ) = @_;
    my @all;
    my $offset = 0;

    while (1) {
        my ( $exit, $stdout, $stderr ) = polymarket_cmd_capture(
            0,         '-o',   'json',     'data', 'positions', $wallet,
            '--limit', $limit, '--offset', $offset
        );
        die "Failed: polymarket data positions\n$stderr\n" if $exit != 0;

        my $arr = json_decode($stdout);
        die "Expected array from data positions\n" unless ref($arr) eq 'ARRAY';

        last if !@$arr;
        push @all, @$arr;
        last if @$arr < $limit;
        $offset += $limit;
    }

    return \@all;
}

sub u256_hex_to_dec {
    my ($hex) = @_;
    return undef unless defined $hex;
    return $hex if $hex =~ /^\d+$/;
    return undef unless $hex =~ /^0x[0-9a-fA-F]+$/;

    require Math::BigInt;
    my $n = Math::BigInt->from_hex($hex);
    return $n->bstr();
}

sub is_hex_0x {
    my ($s) = @_;
    return defined($s) && $s =~ /^0x[0-9a-fA-F]+$/;
}

sub is_u256_0x {
    my ($s) = @_;
    return defined($s) && $s =~ /^0x[0-9a-fA-F]{64}$/;
}

sub is_dec_u256 {
    my ($s) = @_;
    return defined($s) && $s =~ /^\d+$/;
}

# condition_id -> { outcome => { token_hex, token_dec } }
sub fetch_tokens_for_condition {
    my ($condition_id) = @_;

    my $cache = "/tmp/condition-$condition_id.cache.json";
    my $obj;

    if ( -f $cache ) {
        open my $fh, '<', $cache;
        my $json = do { local $/; <$fh> };
        close $fh;
        $obj = json_decode($json);
    }
    else {
        my ( $exit, $stdout, $stderr ) =
          polymarket_cmd_capture( 0, '-o', 'json', 'clob', 'market',
            $condition_id );
        die "Failed: polymarket clob market $condition_id\n$stderr\n"
          if $exit != 0;
        $obj = json_decode($stdout);

        open my $fh, '>', $cache;
        print $fh $stdout;
        close $fh;
    }

    my $tokens = $obj->{tokens};
    die "Missing tokens[] for $condition_id\n" unless ref($tokens) eq 'ARRAY';

    my %map;
    for my $t (@$tokens) {
        next unless ref($t) eq 'HASH';
        my $outcome = $t->{outcome};
        my $hex_id  = $t->{token_id};
        next unless defined $outcome && defined $hex_id;

        my $dec_id = u256_hex_to_dec($hex_id);
        $map{$outcome} = { token_hex => $hex_id, token_dec => $dec_id };
    }

    return \%map;
}

sub normalise_shares {
    my ($shares) = @_;
    return undef unless defined $shares && $shares =~ /^\d+(?:\.\d+)?$/;
    my $s   = $shares + 0;
    my $str = sprintf( "%.8f", $s );
    $str =~ s/0+$// if $str =~ /\./;
    $str =~ s/\.$//;
    return $str;
}

sub looks_like_loser {
    my ($p) = @_;
    my $pp  = $p->{percent_pnl};
    my $cv  = $p->{current_value};
    my $cp  = $p->{cur_price};

    return 1 if defined($pp) && $pp =~ /^-?\d/ && ( $pp + 0 ) <= -99.0;
    return 1
      if defined($cv) && ( $cv + 0 ) == 0 && defined($cp) && ( $cp + 0 ) == 0;
    return 0;
}

sub is_no_orderbook_error {
    my ($err) = @_;
    return 0 unless defined $err;
    return 1 if $err =~ /No orderbook exists/i;
    return 1 if $err =~ /\b404\b/i && $err =~ /\/book/i;
    return 0;
}

sub is_no_market_price_error {
    my ($err) = @_;
    return 0 unless defined $err;
    return 1 if $err =~ /No opposing orders/i;
    return 1 if $err =~ /no market price/i;
    return 0;
}

sub market_sell_one {
    my (%args)    = @_;
    my $token_dec = $args{token_dec};
    my $shares    = $args{shares};

    my @cmd = (
        '-o',       'json',     'clob',   'market-order',
        '--token',  $token_dec, '--side', 'sell',
        '--amount', $shares
    );

    if ( $opt{dry_run} ) {
        return {
            ok      => JSON::PP::true,
            dry_run => JSON::PP::true,
            cmd     => "polymarket " . join( ' ', @cmd )
        };
    }

    my ( $exit, $stdout, $stderr ) = polymarket_cmd_capture( 1, @cmd );

    if ( $exit != 0 ) {
        return {
            ok    => JSON::PP::false,
            error => trim($stderr) || 'Command failed',
            cmd   => "polymarket " . join( ' ', @cmd )
        };
    }

    my $resp = eval { json_decode($stdout) };
    $resp = { raw => $stdout } if $@;
    return { ok => JSON::PP::true, response => $resp };
}

sub limit_sell_one {
    my (%args)    = @_;
    my $token_dec = $args{token_dec};
    my $shares    = $args{shares};
    my $price     = $args{price};

    my @cmd = (
        '-o',      'json',     'clob',   'create-order',
        '--token', $token_dec, '--side', 'sell',
        '--price', $price,     '--size', $shares
    );

    if ( $opt{dry_run} ) {
        return {
            ok      => JSON::PP::true,
            dry_run => JSON::PP::true,
            cmd     => "polymarket " . join( ' ', @cmd )
        };
    }

    my ( $exit, $stdout, $stderr ) = polymarket_cmd_capture( 1, @cmd );
    if ( $exit != 0 ) {
        return {
            ok    => JSON::PP::false,
            error => trim($stderr) || 'Command failed',
            cmd   => "polymarket " . join( ' ', @cmd )
        };
    }

    my $resp = eval { json_decode($stdout) };
    $resp = { raw => $stdout } if $@;
    return { ok => JSON::PP::true, response => $resp };
}

sub redeem_one {
    my (%args) = @_;
    my $condition_id = $args{condition_id};

    my @cmd = ( '-o', 'json', 'ctf', 'redeem', '--condition', $condition_id );

    if ( $opt{dry_run} ) {
        return {
            ok      => JSON::PP::true,
            dry_run => JSON::PP::true,
            cmd     => "polymarket " . join( ' ', @cmd )
        };
    }

    my ( $exit, $stdout, $stderr ) = polymarket_cmd_capture( 1, @cmd );
    if ( $exit != 0 ) {
        return {
            ok    => JSON::PP::false,
            error => trim($stderr) || 'Command failed',
            cmd   => "polymarket " . join( ' ', @cmd )
        };
    }

    my $resp = eval { json_decode($stdout) };
    $resp = { raw => $stdout } if $@;
    return { ok => JSON::PP::true, response => $resp };
}

# ---- Sell resolver (condition id / token hex / token dec) ----

sub build_sell_indexes {
    my ($enriched) = @_;

    my %cond_to_tokens;
    my %token_to_meta;

    for my $e (@$enriched) {
        my $cond     = $e->{condition_id};
        my $tokendec = $e->{token_dec};
        my $slug     = $e->{slug};
        my $shares   = normalise_shares( $e->{shares} );

        next unless defined $cond && defined $tokendec && defined $shares;

        push @{ $cond_to_tokens{$cond} }, $tokendec;

        $token_to_meta{$tokendec}{shares_sum} += ( $shares + 0 );
        push @{ $token_to_meta{$tokendec}{slugs} }, ( $slug // '' );
    }

    for my $c ( keys %cond_to_tokens ) {
        my %seen;
        $cond_to_tokens{$c} =
          [ grep { !$seen{$_}++ } @{ $cond_to_tokens{$c} } ];
    }

    return ( \%cond_to_tokens, \%token_to_meta );
}

sub resolve_sell_targets {
    my ( $sell_arg,       $enriched )      = @_;
    my ( $cond_to_tokens, $token_to_meta ) = build_sell_indexes($enriched);

    # --sell (no arg) => sell all tokens in positions
    if ( !defined($sell_arg) || trim($sell_arg) eq '' ) {
        return { map { $_ => 1 } keys %$token_to_meta };
    }

    my %want;
    for my $raw ( split /,/, $sell_arg ) {
        my $id = trim($raw);
        next if $id eq '';

        # Condition id only if it's in our current positions
        if ( is_u256_0x($id) && exists $cond_to_tokens->{$id} ) {
            $want{$_} = 1 for @{ $cond_to_tokens->{$id} };
            next;
        }

        # Decimal token id
        if ( is_dec_u256($id) ) {
            $want{$id} = 1;
            next;
        }

        # Hex token id (or unknown hex) -> convert to decimal
        if ( is_hex_0x($id) ) {
            my $dec = u256_hex_to_dec($id);
            if ( defined $dec ) {
                $want{$dec} = 1;
            }
            else {
                warn "SKIP invalid hex: $id\n";
            }
            next;
        }

        warn "SKIP unrecognised --sell id: $id\n";
    }

    return \%want;
}

# ---- On-chain sweep (optional) ----
my $HAVE_ETH = 0;
my ( $SW_KEY, $SW_FROM, $SW_NONCE, $SW_GAS_PRICE );

sub load_eth_deps {
    return if $HAVE_ETH;
    eval {
        require Scalar::Util;
        require Math::BigInt;
        require Blockchain::Ethereum::ABI::Encoder;
        require Blockchain::Ethereum::Key;
        require Blockchain::Ethereum::Transaction::Legacy;
        1;
    }
      or die
      "Missing deps for sweep/onchain. Install: cpanm Blockchain::Ethereum\n$@";
    $HAVE_ETH = 1;
}

sub rpc_call {
    my ( $method, $params ) = @_;
    $params ||= [];

    die "RPC missing (use --rpc or RPC_URL)\n"
      unless defined $opt{rpc} && length $opt{rpc};

    my $payload = JSON::PP->new->utf8->encode(
        {
            jsonrpc => "2.0",
            id      => 1,
            method  => $method,
            params  => $params,
        }
    );

    my ( $exit, $stdout, $stderr ) =
      run_cmd_capture( 'curl', '-sS', '-X', 'POST',
        '-H',     'Content-Type: application/json',
        '--data', $payload, $opt{rpc} );

    die "RPC transport failed: $stderr\n" if $exit != 0;

    my $res = json_decode($stdout);
    die "RPC error: " . json_encode_pretty( $res->{error} ) . "\n"
      if $res->{error};
    return $res->{result};
}

sub hex_to_bigint {
    my ($hex) = @_;
    $hex //= '0x0';
    $hex =~ s/^\s+|\s+$//g;
    $hex =~ s/^0x//i;
    $hex = '0' if $hex eq '';
    return Math::BigInt->from_hex( '0x' . $hex );
}

sub bigint_to_hex {
    my ($bi) = @_;
    my $h = $bi->as_hex();
    $h =~ s/^0x/0x/;
    return $h;
}

sub clamp_gas_price_hex {
    my ( $gp_hex, $min_gwei ) = @_;
    my $gp = hex_to_bigint($gp_hex);

    my $minwei = Math::BigInt->new($min_gwei);
    $minwei->bmul( Math::BigInt->new('1000000000') );

    return ( $gp->bcmp($minwei) >= 0 )
      ? bigint_to_hex($gp)
      : bigint_to_hex($minwei);
}

sub to_uint256_decimal_string {
    my ($id) = @_;
    return $id if defined $id && $id =~ /^\d+$/;

    my $hex = $id // '';
    $hex =~ s/^0x//i;
    $hex = '0' if $hex eq '';

    my $bi = Math::BigInt->from_hex( '0x' . $hex );
    return $bi->bstr();
}

sub ctf_balance_of {
    my ( $owner, $token_hex ) = @_;
    load_eth_deps();

    return '0' unless defined $token_hex && $token_hex =~ /^0x[0-9a-fA-F]+$/;

    my $token_dec = to_uint256_decimal_string($token_hex);

    my $enc  = Blockchain::Ethereum::ABI::Encoder->new;
    my $data = $enc->function('balanceOf')->append( address => $owner )
      ->append( uint256 => $token_dec )->encode();

    my $ret = rpc_call( 'eth_call',
        [ { to => $CTF_ERC1155, data => $data }, 'latest' ] );
    $ret //= '0x0';
    $ret =~ s/^0x//i;
    $ret = '0' if $ret eq '';

    my $bi = Math::BigInt->from_hex( '0x' . $ret );
    return $bi->bstr();
}

sub build_ctf_safeTransferFrom_calldata {
    my (%p) = @_;
    load_eth_deps();

    my $from     = $p{from};
    my $to       = $p{to};
    my $tokenhex = $p{token_hex};
    my $amount   = $p{amount};

    my $token_dec = to_uint256_decimal_string($tokenhex);

    my $enc = Blockchain::Ethereum::ABI::Encoder->new;
    my $data =
      $enc->function('safeTransferFrom')->append( address => $from )
      ->append( address => $to )->append( uint256 => $token_dec )
      ->append( uint256 => "$amount" )->append( bytes => '00' )->encode();

    return $data;    # 0x...
}

sub normalise_raw_tx_hex {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/^\s+|\s+$//g;

    if ( $raw !~ /\A0x?[0-9a-fA-F]*\z/ ) {
        $raw = unpack( "H*", $raw );
    }

    $raw =~ s/^0x//i;
    $raw =~ s/\s+//g;
    $raw = "0$raw" if ( length($raw) % 2 ) == 1;
    return "0x$raw";
}

sub hex_add_int {
    my ( $hex, $n ) = @_;
    my $bi = hex_to_bigint($hex);
    $bi->badd($n);
    return bigint_to_hex($bi);
}

sub sweep_init_signer {
    load_eth_deps();

    die "--private-key missing (or PRIVATE_KEY)\n"
      unless defined $opt{private_key} && length $opt{private_key};
    my $pk = $opt{private_key};
    $pk =~ s/^0x//i;
    die "private key must be 32 bytes hex\n" unless $pk =~ /^[0-9a-fA-F]{64}$/;

    $SW_KEY =
      Blockchain::Ethereum::Key->new( private_key => pack( "H*", $pk ) );
    $SW_FROM = '' . $SW_KEY->address;

    die "--address does not match private key address ($SW_FROM)\n"
      unless lc($SW_FROM) eq lc( $opt{address} );

    $SW_NONCE = rpc_call( 'eth_getTransactionCount', [ $SW_FROM, 'pending' ] );
    $SW_GAS_PRICE = rpc_call( 'eth_gasPrice', [] );
    $SW_GAS_PRICE = clamp_gas_price_hex( $SW_GAS_PRICE, $opt{min_gwei} );

    if ( $opt{verbose} ) {
        print "Sweep signer: $SW_FROM\n";
        print "Sweep start nonce: $SW_NONCE\n";
        print "Sweep gas price: $SW_GAS_PRICE\n";
    }
}

sub sweep_send_tx {
    my (%p) = @_;
    load_eth_deps();

    my $to    = $p{to};
    my $data  = $p{data};
    my $value = '0x0';

    my $estimate = rpc_call(
        'eth_estimateGas',
        [
            {
                from  => $SW_FROM,
                to    => $to,
                value => $value,
                data  => $data,
            }
        ]
    );

    my $gas_limit;
    {
        my $g = hex_to_bigint($estimate);
        $g->bmul(125);
        $g->bdiv(100);
        $gas_limit = bigint_to_hex($g);
    }

    my $tx = Blockchain::Ethereum::Transaction::Legacy->new(
        nonce     => $SW_NONCE,
        gas_price => $SW_GAS_PRICE,
        gas_limit => $gas_limit,
        to        => $to,
        value     => $value,
        data      => $data,
        chain_id  => $CHAIN_ID_HEX,
    );

    $SW_KEY->sign_transaction($tx);

    my $raw    = normalise_raw_tx_hex( $tx->serialize );
    my $txhash = rpc_call( 'eth_sendRawTransaction', [$raw] );

    $SW_NONCE = hex_add_int( $SW_NONCE, 1 );
    return $txhash;
}

sub sweep_outcome_token {
    my (%args) = @_;
    my $token_hex = $args{token_hex};

    die "--sweep-to missing\n"
      unless defined $opt{sweep_to} && $opt{sweep_to} =~ /^0x[0-9a-fA-F]{40}$/;

    my $bal = ctf_balance_of( $opt{address}, $token_hex );
    return {
        ok      => JSON::PP::true,
        skipped => JSON::PP::true,
        reason  => 'balance=0'
      }
      if !$bal || $bal !~ /^\d+$/ || $bal eq '0';

    if ( $opt{dry_run} ) {
        return {
            ok        => JSON::PP::true,
            dry_run   => JSON::PP::true,
            amount    => $bal,
            token_hex => $token_hex,
            to        => $opt{sweep_to}
        };
    }

    my $calldata = build_ctf_safeTransferFrom_calldata(
        from      => $opt{address},
        to        => $opt{sweep_to},
        token_hex => $token_hex,
        amount    => $bal,
    );

    my $txhash = sweep_send_tx( to => $CTF_ERC1155, data => $calldata );
    return {
        ok        => JSON::PP::true,
        txhash    => $txhash,
        amount    => $bal,
        token_hex => $token_hex,
        to        => $opt{sweep_to}
    };
}

# ---- Pretty output ----

sub fmt_pct {
    my ($s) = @_;
    return ''                      if !defined $s;
    return sprintf( "%.2f%%", $s ) if $s =~ /^-?\d+(?:\.\d+)?$/;
    return "$s%";
}

sub fmt_cash {
    my ($s) = @_;
    return ''                    if !defined $s;
    return sprintf( "%.2f", $s ) if $s =~ /^-?\d+(?:\.\d+)?$/;
    return "$s";
}

sub ascii_table {
    my ( $rows, $cols ) = @_;
    my @width = map { length($_) } @$cols;

    for my $r (@$rows) {
        for my $i ( 0 .. $#$cols ) {
            my $k = $cols->[$i];
            my $v = defined $r->{$k} ? $r->{$k} : '';
            $width[$i] = length($v) if length($v) > $width[$i];
        }
    }

    my $line = '+';
    for my $w (@width) { $line .= ( '-' x ( $w + 2 ) ) . '+'; }
    $line .= "\n";

    my $out = $line . '|';
    for my $i ( 0 .. $#$cols ) {
        $out .= ' ' . sprintf( "%-*s", $width[$i], $cols->[$i] ) . ' |';
    }
    $out .= "\n" . $line;

    for my $r (@$rows) {
        $out .= '|';
        for my $i ( 0 .. $#$cols ) {
            my $k = $cols->[$i];
            my $v = defined $r->{$k} ? $r->{$k} : '';
            $out .= ' ' . sprintf( "%-*s", $width[$i], $v ) . ' |';
        }
        $out .= "\n";
    }

    $out .= $line;
    return $out;
}

# ----------------------------
# Main
# ----------------------------
my $wallet = $opt{address} // get_wallet_address_from_cli();
$opt{address} = $wallet;

my $positions = fetch_all_positions( $wallet, $opt{page_size} );

my %cond_cache;
my @enriched;

for my $p (@$positions) {
    next unless ref($p) eq 'HASH';

    my $slug         = $p->{slug};
    my $outcome      = $p->{outcome};
    my $condition_id = $p->{condition_id};
    next unless defined $condition_id && defined $outcome;

    $cond_cache{$condition_id} //= fetch_tokens_for_condition($condition_id);
    my $tokinfo = $cond_cache{$condition_id}{$outcome} || {};

    push @enriched,
      {
        slug          => $slug,
        outcome       => $outcome,
        shares        => $p->{size},
        cash_pnl      => $p->{cash_pnl},
        percent_pnl   => $p->{percent_pnl},
        condition_id  => $condition_id,
        redeemable    => $p->{redeemable} ? JSON::PP::true : JSON::PP::false,
        cur_price     => $p->{cur_price},
        current_value => $p->{current_value},
        token_hex     => $tokinfo->{token_hex},
        token_dec     => $tokinfo->{token_dec},
      };
}

my $want_sweep =
     ( $opt{close} || $opt{with_onchain} || $opt{hide_cleared} )
  && defined( $opt{sweep_to} )
  && $opt{sweep_to} =~ /^0x[0-9a-fA-F]{40}$/;

my $need_onchain =
  $opt{with_onchain} || $opt{hide_cleared} || ( $opt{close} && $want_sweep );

if ($need_onchain) {
    die "--rpc is required for on-chain balance checks\n"
      unless defined $opt{rpc} && length $opt{rpc};
    for my $e (@enriched) {
        next
          unless defined $e->{token_hex}
          && $e->{token_hex} =~ /^0x[0-9a-fA-F]+$/;
        $e->{onchain_balance} = ctf_balance_of( $wallet, $e->{token_hex} );
    }
}

if ($want_sweep) {
    die "--rpc is required for sweeping\n"
      unless defined $opt{rpc} && length $opt{rpc};
    die "--private-key is required for sweeping\n"
      unless defined $opt{private_key} && length $opt{private_key};
    sweep_init_signer();
}

# --- Manual sell block ---
my @sell_results;
if ( defined $opt{sell} ) {
    my $want_tokens = resolve_sell_targets( $opt{sell}, \@enriched );

    my %sum_shares;
    my %slug_for;

    for my $e (@enriched) {
        my $tid = $e->{token_dec};
        next unless defined $tid;
        next unless $want_tokens->{$tid};

        my $sh = normalise_shares( $e->{shares} );
        next unless defined $sh;

        $sum_shares{$tid} += ( $sh + 0 );
        $slug_for{$tid} = $e->{slug} if defined $e->{slug};
    }

    for my $tid ( sort keys %$want_tokens ) {
        if ( !exists $sum_shares{$tid} ) {
            push @sell_results,
              {
                token_dec => $tid,
                ok        => JSON::PP::false,
                error     =>
                  "Nothing to sell for this id (not in current positions)."
              };
            next;
        }

        my $shares = sprintf( "%.8f", $sum_shares{$tid} );
        $shares =~ s/0+$// if $shares =~ /\./;
        $shares =~ s/\.$//;

        my $res;
        if ( defined $opt{limit} ) {
            $res = limit_sell_one(
                token_dec => $tid,
                shares    => $shares,
                price     => $opt{limit}
            );
        }
        else {
            $res = market_sell_one( token_dec => $tid, shares => $shares );
        }

        push @sell_results,
          {
            token_dec => $tid,
            slug      => $slug_for{$tid},
            shares    => $shares,
            %$res,
          };
    }
}

# --- Auto close block ---
my @actions;
if ( $opt{close} ) {
    my $done = 0;

  POSITION:
    for my $e (@enriched) {
        last if $opt{max_actions} && $done >= $opt{max_actions};

        my $slug       = $e->{slug} // '';
        my $cond       = $e->{condition_id};
        my $redeemable = $e->{redeemable} ? 1 : 0;

        # If we have onchain balance and it is 0, skip
        if (   defined $e->{onchain_balance}
            && $e->{onchain_balance} =~ /^\d+$/
            && $e->{onchain_balance} eq '0' )
        {
            push @actions,
              {
                slug   => $slug,
                action => 'skip',
                ok     => JSON::PP::true,
                reason => 'cleared_onchain'
              };
            next POSITION;
        }

        if ($redeemable) {

  # losers: sweep if configured; otherwise skip (redeem does nothing for losers)
            if ( $opt{sweep_losers} && $want_sweep && looks_like_loser($e) ) {
                if ( !defined $e->{token_hex} ) {
                    push @actions,
                      {
                        slug   => $slug,
                        action => 'sweep_loser',
                        ok     => JSON::PP::false,
                        error  => 'missing token_hex'
                      };
                    $done++;
                    next POSITION;
                }
                my $res = sweep_outcome_token( token_hex => $e->{token_hex} );
                push @actions,
                  {
                    slug         => $slug,
                    action       => 'sweep_loser',
                    condition_id => $cond,
                    %$res
                  };
                $done++;
                next POSITION;
            }

            if ( looks_like_loser($e) && !$want_sweep ) {
                push @actions,
                  {
                    slug   => $slug,
                    action => 'skip',
                    ok     => JSON::PP::true,
                    reason => 'loser_no_sweep'
                  };
                next POSITION;
            }

            my $res = redeem_one( condition_id => $cond );
            push @actions,
              {
                slug         => $slug,
                action       => 'redeem',
                condition_id => $cond,
                %$res
              };
            $done++;
            next POSITION;
        }

        # Not redeemable: try sell
        my $shares    = normalise_shares( $e->{shares} );
        my $token_dec = $e->{token_dec};

        if ( !defined $shares || !defined $token_dec ) {
            push @actions,
              {
                slug   => $slug,
                action => 'sell',
                ok     => JSON::PP::false,
                error  => 'missing shares/token_dec'
              };
            $done++;
            next POSITION;
        }

        my $sell_res =
          market_sell_one( token_dec => $token_dec, shares => $shares );
        if ( $sell_res->{ok} ) {
            push @actions,
              {
                slug      => $slug,
                action    => 'sell',
                token_dec => $token_dec,
                shares    => $shares,
                %$sell_res
              };
            $done++;
            next POSITION;
        }

        # Zombie: no orderbook at all -> sweep if configured
        if (   $opt{sweep_zombie}
            && $want_sweep
            && is_no_orderbook_error( $sell_res->{error} ) )
        {
            if ( !defined $e->{token_hex} ) {
                push @actions,
                  {
                    slug       => $slug,
                    action     => 'sweep_zombie',
                    ok         => JSON::PP::false,
                    error      => 'missing token_hex',
                    sell_error => $sell_res->{error}
                  };
                $done++;
                next POSITION;
            }
            my $res = sweep_outcome_token( token_hex => $e->{token_hex} );
            push @actions,
              {
                slug       => $slug,
                action     => 'sweep_zombie',
                token_dec  => $token_dec,
                sell_error => $sell_res->{error},
                %$res
              };
            $done++;
            next POSITION;
        }

        # Illiquid: no market price. Optional sweep (guarded by current_value)
        if (   $opt{sweep_illiquid}
            && $want_sweep
            && is_no_market_price_error( $sell_res->{error} ) )
        {
            my $cv = $e->{current_value};
            my $cv_num =
              ( defined($cv) && $cv =~ /^-?\d+(?:\.\d+)?$/ ) ? ( $cv + 0 ) : 0;

            if ( $cv_num <= ( $opt{illiquid_max_value} + 0 ) ) {
                if ( !defined $e->{token_hex} ) {
                    push @actions,
                      {
                        slug       => $slug,
                        action     => 'sweep_illiquid',
                        ok         => JSON::PP::false,
                        error      => 'missing token_hex',
                        sell_error => $sell_res->{error}
                      };
                    $done++;
                    next POSITION;
                }
                my $res = sweep_outcome_token( token_hex => $e->{token_hex} );
                push @actions,
                  {
                    slug       => $slug,
                    action     => 'sweep_illiquid',
                    token_dec  => $token_dec,
                    sell_error => $sell_res->{error},
                    %$res
                  };
                $done++;
                next POSITION;
            }
        }

        push @actions,
          {
            slug      => $slug,
            action    => 'sell',
            token_dec => $token_dec,
            shares    => $shares,
            %$sell_res
          };
        $done++;
    }
}

# ---- Output ----

if ( $opt{output} eq 'json' ) {
    my $payload = {
        ts     => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
        wallet => $wallet,
        mode   => (
            $opt{close} ? 'close' : ( defined( $opt{sell} ) ? 'sell' : 'list' )
        ),
        sweep_to  => $opt{sweep_to},
        dry_run   => ( $opt{dry_run} ? JSON::PP::true : JSON::PP::false ),
        positions => \@enriched,
        actions   => \@actions,
        sells     => \@sell_results,
    };
    print json_encode_pretty($payload);
    exit 0;
}

print "Wallet: $wallet\n";
print "Mode: "
  . ( $opt{close} ? "AUTO CLOSE" : ( defined( $opt{sell} ) ? "SELL" : "LIST" ) )
  . "\n";
print "Signature type: "
  . ( defined $opt{signature_type} ? $opt{signature_type} : "default" ) . "\n";
print "Sweep to: "
  . ( defined $opt{sweep_to} ? $opt{sweep_to} : "not set" ) . "\n";
print "Dry run: " . ( $opt{dry_run} ? "yes" : "no" ) . "\n\n";

my @cols = ( 'Token (dec)', 'Slug', 'PnL %', 'PnL (cash)' );
push @cols, ( 'Onchain Bal', 'Redeemable' ) if $opt{with_onchain};

my @rows;
for my $e (@enriched) {
    if (   $opt{hide_cleared}
        && defined( $e->{onchain_balance} )
        && $e->{onchain_balance} =~ /^\d+$/
        && $e->{onchain_balance} eq '0' )
    {
        next;
    }

    my %r = (
        'Token (dec)' => ( defined $e->{token_dec} ? $e->{token_dec} : 'N/A' ),
        'Slug'        => ( $e->{slug} // '' ),
        'PnL %'       => fmt_pct( $e->{percent_pnl} ),
        'PnL (cash)'  => fmt_cash( $e->{cash_pnl} ),
    );

    if ( $opt{with_onchain} ) {
        $r{'Onchain Bal'} =
          ( defined $e->{onchain_balance} ? $e->{onchain_balance} : 'N/A' );
        $r{'Redeemable'} = ( $e->{redeemable} ? 'true' : 'false' );
    }

    push @rows, \%r;
}

if (@rows) {
    print ascii_table( \@rows, \@cols );
}
else {
    print "No positions.\n";
}

if ( defined $opt{sell} ) {
    print "\nSell results:\n";
    for my $r (@sell_results) {
        my $ok  = $r->{ok} ? 'OK' : 'ERR';
        my $msg = $r->{error} // '';
        printf "  [%s] token=%s shares=%s %s\n",
          $ok,
          ( $r->{token_dec} // '' ),
          ( $r->{shares}    // '' ),
          ( $msg ? "($msg)" : '' );
    }
}

if ( $opt{close} ) {
    print "\nActions:\n";
    for my $a (@actions) {
        my $ok  = $a->{ok} ? 'OK' : 'ERR';
        my $act = $a->{action} // 'unknown';
        my $msg = $a->{error}  // $a->{reason} // '';
        printf "  [%s] %-14s %s %s\n", $ok, $act, ( $a->{slug} // '' ),
          ( $msg ? "($msg)" : '' );
    }
}
