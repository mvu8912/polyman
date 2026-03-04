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

done_testing();
