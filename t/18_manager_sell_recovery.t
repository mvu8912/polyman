use strict;
use warnings;

use Test::More;
use JSON::PP;
use lib 'lib';
use Manager;

{
    package FakeAPI;

    sub new {
        my ($class, %args) = @_;
        return bless { %args }, $class;
    }

    sub market_sell {
        my ($self, %args) = @_;
        return shift @{ $self->{sell_responses} };
    }

    sub redeem_condition {
        my ($self, %args) = @_;
        return shift @{ $self->{redeem_responses} };
    }

    sub close_zero_value_position {
        my ($self, %args) = @_;
        return shift @{ $self->{sweep_responses} };
    }
}

my $m = bless {
    cfg => {
        loser_sweep_to => '0x2222222222222222222222222222222222222222',
    },
}, 'Manager';

my $task = {
    action       => 'stop_hit',
    token_dec    => '123',
    amount       => '1.0',
    condition_id => '0xabc',
    position_key => '0xabc:Up',
    index_set    => 1,
};

my $redeem_task = {
    action       => 'redeem',
    token_dec    => '123',
    amount       => '1.0',
    condition_id => '0xabc',
    position_key => '0xabc:Up',
    index_set    => 1,
};

{
    no warnings 'redefine';
    local *Manager::_verify_task_effect = sub {
        my ($self, $api, $task) = @_;
        return (1, 'verified position clear on attempt=1');
    };

    my $api = FakeAPI->new(
        sell_responses   => [ { ok => JSON::PP::false, error => 'sell failed' } ],
        redeem_responses => [ { ok => JSON::PP::true, response => { redeemed => JSON::PP::true } } ],
        sweep_responses  => [],
    );

    my $res = $m->_execute_task_with_recovery($api, $task);
    ok($res->{ok}, 'sell failure can recover via redeem');
    like($res->{verify_note}, qr/sell_failed_then_redeem/, 'verify note records redeem fallback path');
    is($res->{res}{attempts}[0]{action}, 'sell', 'first attempt is sell');
    is($res->{res}{attempts}[1]{action}, 'redeem', 'second attempt is redeem');
}

{
    no warnings 'redefine';
    local *Manager::_verify_task_effect = sub {
        my ($self, $api, $task) = @_;
        return (1, 'verified position clear on attempt=1');
    };

    my $api = FakeAPI->new(
        sell_responses   => [ { ok => JSON::PP::false, error => 'sell failed' } ],
        redeem_responses => [ { ok => JSON::PP::false, error => 'redeem failed' } ],
        sweep_responses  => [ { ok => JSON::PP::true, response => { tx => '0x1' } } ],
    );

    my $res = $m->_execute_task_with_recovery($api, $task);
    ok($res->{ok}, 'sell + redeem failure can recover via sweep');
    like($res->{verify_note}, qr/sell_redeem_failed_then_sweep/, 'verify note records sweep fallback path');
    is($res->{res}{attempts}[2]{action}, 'transfer', 'third attempt is transfer sweep');
}

{
    no warnings 'redefine';
    local *Manager::_verify_task_effect = sub {
        my ($self, $api, $task) = @_;
        return (0, 'post-action verify timeout after 60s: position still present key=0xabc:Up');
    };

    my $api = FakeAPI->new(
        sell_responses   => [ { ok => JSON::PP::false, error => 'sell failed' } ],
        redeem_responses => [ { ok => JSON::PP::true, response => { redeemed => JSON::PP::true } } ],
        sweep_responses  => [ { ok => JSON::PP::true, response => { tx => '0x1' } } ],
    );

    my $res = $m->_execute_task_with_recovery($api, $task);
    ok(!$res->{ok}, 'redeem success with verify timeout still fails task');
    like($res->{error}, qr/post-action verify timeout/, 'verify timeout is preserved as failure reason');
}

{
    no warnings 'redefine';
    my $call = 0;
    local *Manager::_verify_task_effect = sub {
        my ($self, $api, $task) = @_;
        $call++;
        return $call == 1
            ? (0, 'post-action verify timeout after 60s: position still present key=0xabc:Up')
            : (1, 'verified position clear on attempt=1');
    };

    my $api = FakeAPI->new(
        sell_responses   => [],
        redeem_responses => [ { ok => JSON::PP::true, response => { redeemed => JSON::PP::true } } ],
        sweep_responses  => [ { ok => JSON::PP::true, response => { tx => '0x2' } } ],
    );

    my $res = $m->_execute_task_with_recovery($api, $redeem_task);
    ok($res->{ok}, 'redeem verify-timeout falls back to sweep transfer and can recover');
    like($res->{verify_note}, qr/redeem_verify_failed_then_sweep/, 'verify note records redeem->sweep path');
    is($res->{res}{attempts}[0]{action}, 'redeem', 'first attempt is redeem');
    is($res->{res}{attempts}[1]{action}, 'transfer', 'second attempt is transfer sweep');
}

done_testing;
