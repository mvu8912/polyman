use strict;
use warnings;

use Test::More;
use lib 't/lib';
use lib 'lib';

use Manager;

{
    package MockPositionsAPI;
    sub token_dec_for_position {
        my ($self, $p) = @_;
        return '777' if ($p->{condition_id} // '') eq 'c1';
        return undef;
    }
}

my $m = bless {
    positions_api => bless({}, 'MockPositionsAPI'),
}, 'Manager';

is(
    $m->_resolve_token_dec({ condition_id => 'c1', outcome => 'Yes' }),
    '777',
    '_resolve_token_dec uses positions_api token_dec_for_position',
);

$m->{positions_api} = undef;

is(
    $m->_resolve_token_dec({ asset_id => '123' }),
    '123',
    '_resolve_token_dec falls back to asset_id when API helper unavailable',
);

done_testing();
