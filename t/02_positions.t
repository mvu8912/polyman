use strict;
use warnings;

use Test::More;
use lib 't/lib';
use lib 'lib';

{
    package TestPositions;
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

my $p1 = TestPositions->new_with_responses([
    [0, " 0x1111111111111111111111111111111111111111\n", ''],
]);
is($p1->wallet_address, '0x1111111111111111111111111111111111111111', 'wallet address happy path');

my $p2 = TestPositions->new_with_responses([
    [0, "not-an-address\n", ''],
]);
eval { $p2->wallet_address };
like($@, qr/Could not parse wallet address/, 'wallet sad path invalid format');

my $p3 = TestPositions->new_with_responses([
    [0, '[{"asset_id":"1"},{"asset_id":"2"}]', ''],
    [0, '[{"asset_id":"3"}]', ''],
], page_size => 2);
my $all = $p3->fetch_positions('0x1111111111111111111111111111111111111111');
is(scalar(@$all), 3, 'pagination works');


my $p3b = TestPositions->new_with_responses([
    [0, '[{"condition_id":"c1","outcome":"Yes","size":"1"}]', ''],
    [0, '[]', ''],
    [0, '[{"condition_id":"c2","outcome":"No"}]', ''],
    [0, '[]', ''],
], page_size => 1);
my $all_manageable = $p3b->fetch_manageable_positions('0x1111111111111111111111111111111111111111');
is(scalar(@$all_manageable), 2, 'fetch_manageable_positions merges open and hidden closed positions');
ok(!$all_manageable->[0]{_hidden}, 'open position not marked hidden');
ok($all_manageable->[1]{_hidden}, 'closed-only position marked hidden');
ok($all_manageable->[1]{redeemable}, 'closed-only position is considered redeemable candidate');

my $p4 = TestPositions->new_with_responses([
    [0, '{"status":"ok"}', ''],
]);
my $sell_ok = $p4->market_sell(token_dec => '123', amount => '1.0');
ok($sell_ok->{ok}, 'market_sell happy path');

my $p5 = TestPositions->new_with_responses([
    [1, '', 'No book'],
]);
my $sell_err = $p5->market_sell(token_dec => '123', amount => '1.0');
ok(!$sell_err->{ok}, 'market_sell sad path');
like($sell_err->{error}, qr/No book/, 'market_sell returns error');

my $p5b = TestPositions->new_with_responses([
    [1, '', '{"error":"not enough balance / allowance"}'],
    [0, 'Balance allowance updated.', ''],
    [0, '{"status":"ok"}', ''],
]);
my $sell_recover = $p5b->market_sell(token_dec => '123', amount => '1.0');
ok($sell_recover->{ok}, 'market_sell retries after balance/allowance sync');

my $p5c = TestPositions->new_with_responses([
    [1, '', '{"error":"not enough balance / allowance"}'],
    [0, 'Balance allowance updated.', ''],
    [1, '', '{"error":"not enough balance / allowance"}'],
]);
my $sell_needs_approval = $p5c->market_sell(token_dec => '123', amount => '1.0');
ok(!$sell_needs_approval->{ok}, 'market_sell still fails when approval is truly missing');
like($sell_needs_approval->{error}, qr/polymarket approve set/, 'market_sell provides approve hint on persistent allowance failure');

my $p6 = TestPositions->new_with_responses([
    [0, '{"redeemed":true}', ''],
    [1, '', 'redeem failed'],
]);
my $r_ok = $p6->redeem_condition(condition_id => '0xabc');
ok($r_ok->{ok}, 'redeem happy path');
my $r_bad = $p6->redeem_condition(condition_id => '0xabc');
ok(!$r_bad->{ok}, 'redeem sad path');


my $p7 = TestPositions->new_with_responses([
    [0, '{"tokens":[{"outcome":"Yes","outcome_index":0,"token_id":"0xcb2c8ca36d7a765f04440834778b68d910e44d4d277f0792f012db64f0f94ac8"},{"outcome":"No","outcome_index":1,"token_id":"0xc30392f1548a7e43b61763e6b7a3d2631ef073835b19f133936e0f5683e9bd08"}]}', ''],
]);
is(
    $p7->token_dec_for_position({
        condition_id => '0xcond',
        outcome => 'Yes',
        outcome_index => 0,
    }),
    '91898220183742601070760510452630848054828384834207792757174701092455484836552',
    'token_dec_for_position resolves hex token_id via condition_id + clob market tokens',
);

my $p8 = TestPositions->new_with_responses([
    [1, '', 'boom'],
]);
is(
    $p8->token_dec_for_position({ condition_id => '0xcond', clob_token_id => '999' }),
    '999',
    'token_dec_for_position falls back to clob_token_id when market lookup fails',
);

{
    package CmdCapturePositions;
    use parent 'Positions';

    sub new_with_results {
        my ($class, $results, %args) = @_;
        my $self = $class->SUPER::new(%args);
        $self->{_results} = $results;
        $self->{_calls} = [];
        return $self;
    }

    sub run_cmd_capture {
        my ($self, @cmd) = @_;
        push @{ $self->{_calls} }, [@cmd];
        my $r = shift @{ $self->{_results} };
        return @$r;
    }

    sub calls { return $_[0]{_calls}; }
}

{
    package FallbackPositions;
    use parent -norequire, 'CmdCapturePositions';

    sub _sweep_transfer_via_raw_tx {
        my ($self, %args) = @_;
        $self->{_fallback_args} = \%args;
        die "forced fallback failure\n" if $self->{_fallback_fail};
        return '0xdeadbeef';
    }

    sub fallback_args { return $_[0]{_fallback_args}; }
}

my $p9 = CmdCapturePositions->new_with_results([
    [1, '', 'No wallet configured'],
    [0, '{"ok":true}', ''],
],
    signature_type => 'proxy',
    private_key => '0xabc',
    wallet_address => '0x1111111111111111111111111111111111111111',
);
my $p9s = $p9->market_sell(token_dec => '123', amount => '1.0');
ok($p9s->{ok}, 'market_sell retries with private key flag after wallet-config error');
is(scalar @{ $p9->calls }, 2, 'polymarket invoked twice (initial + private-key retry)');
my $second = join(' ', @{ $p9->calls->[1] });
like($second, qr/--private-key 0xabc/, 'private-key flag added on retry');

my $old_pm_pk = exists $ENV{POLYMARKET_PRIVATE_KEY} ? $ENV{POLYMARKET_PRIVATE_KEY} : undef;
my $old_pm_wa = exists $ENV{POLYMARKET_WALLET_ADDRESS} ? $ENV{POLYMARKET_WALLET_ADDRESS} : undef;

my $p10 = CmdCapturePositions->new_with_results([
    [0, '{"ok":true}', ''],
],
    signature_type => 'proxy',
    private_key => '0xabc',
    wallet_address => '0x1111111111111111111111111111111111111111',
);
$p10->market_sell(token_dec => '123', amount => '1.0');

is((exists $ENV{POLYMARKET_PRIVATE_KEY} ? $ENV{POLYMARKET_PRIVATE_KEY} : undef), $old_pm_pk, 'POLYMARKET_PRIVATE_KEY restored after command');
is((exists $ENV{POLYMARKET_WALLET_ADDRESS} ? $ENV{POLYMARKET_WALLET_ADDRESS} : undef), $old_pm_wa, 'POLYMARKET_WALLET_ADDRESS restored after command');


my $p10b = CmdCapturePositions->new_with_results([
    [1, 'raw-out', "raw-err"],
],
    signature_type => 'proxy',
    private_key => '0xabc',
    wallet_address => '0x1111111111111111111111111111111111111111',
);
my $sell_err_debug = $p10b->market_sell(token_dec => '123', amount => '1.0');
ok(!$sell_err_debug->{ok}, 'market_sell returns failure when command exits non-zero');
like($sell_err_debug->{error}, qr/Command debug:/, 'error includes command debug header');
like($sell_err_debug->{error}, qr/cmd=polymarket --signature-type proxy -o json clob market-order --token 123 --side sell --amount 1\.00/, 'error includes rendered command and args');
like($sell_err_debug->{error}, qr/stdout_raw=raw-out/, 'error includes raw stdout for debugging');
like($sell_err_debug->{error}, qr/stderr_raw=raw-err/, 'error includes raw stderr for debugging');

my $p11 = FallbackPositions->new_with_results([], 
    signature_type => 'proxy',
    private_key => '0xabc',
    wallet_address => '0x1111111111111111111111111111111111111111',
);
my $c11 = $p11->close_zero_value_position(
    token_dec => '123',
    amount => '2.0',
    condition_id => '0xcond',
    sweep_to => '0x2222222222222222222222222222222222222222',
    prefer_sweep => 1,
);
ok($c11->{ok}, 'prefer_sweep path can succeed via transfer first');
is($c11->{action}, 'transfer', 'prefer_sweep returns transfer action');
is($c11->{attempts}[0]{method}, 'raw_tx', 'prefer_sweep uses raw tx transfer path');
is(scalar @{ $p11->calls }, 0, 'prefer_sweep success does not call sell/redeem');

my $p12 = FallbackPositions->new_with_results([], 
    signature_type => 'proxy',
    private_key => '0xabc',
    wallet_address => '0x1111111111111111111111111111111111111111',
);
my $x12 = $p12->close_zero_value_position(
    token_dec => '123',
    amount => '2.0',
    condition_id => '0xcond',
    sweep_to => '0x2222222222222222222222222222222222222222',
    prefer_sweep => 1,
);
ok($x12->{ok}, 'transfer can use raw tx');
is($x12->{action}, 'transfer', 'raw tx transfer reports transfer action');
is($x12->{attempts}[0]{method}, 'raw_tx', 'method is raw tx');
is($x12->{attempts}[0]{txhash}, '0xdeadbeef', 'returns tx hash');
is($p12->fallback_args->{token_dec}, '123', 'raw tx called with token_dec');

my $p13 = FallbackPositions->new_with_results([
    [1, '', 'sell failed'],
    [1, '', 'redeem failed'],
    [1, '', 'sell failed'],
],
    signature_type => 'proxy',
    private_key => '0xabc',
    wallet_address => '0x1111111111111111111111111111111111111111',
);
$p13->{_fallback_fail} = 1;
my $x13 = $p13->close_zero_value_position(
    token_dec => '123',
    amount => '2.0',
    condition_id => '0xcond',
    sweep_to => '0x2222222222222222222222222222222222222222',
    prefer_sweep => 1,
);
ok(!$x13->{ok}, 'transfer propagates failure when raw tx fails');
like($x13->{attempts}[0]{error}, qr/forced fallback failure/, 'raw tx failure message included');

done_testing();
