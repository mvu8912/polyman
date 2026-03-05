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
    '0xcb2c8ca36d7a765f04440834778b68d910e44d4d277f0792f012db64f0f94ac8',
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

done_testing();
