use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile tempdir);
use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

my $tmpd = tempdir(CLEANUP => 1);
my ($fh, $state_path) = tempfile(DIR => $tmpd);
close $fh;

my $m = bless {
    cfg => {
        state_file => $state_path,
        result_dir => $tmpd,
        worker_max_retries => 5,
        signature_type => '',
    },
    state => {
        positions => {
            'c1:YES' => {
                queued => { close_loser => JSON::PP::true },
                done => {},
            },
        },
    },
    pending_tasks => [],
    active_workers => {},
    last_snapshot => {},
}, 'Manager';

$m->_retry_or_clear({ action => 'close_loser', position_key => 'c1:YES', retries => 0 }, 'unable to close zero value position');
ok($m->{state}{positions}{'c1:YES'}{done}{close_loser}, 'close_loser marked done after permanent close failure');
ok(!$m->{state}{positions}{'c1:YES'}{queued}{close_loser}, 'queued close_loser cleared after give up');
is(scalar @{ $m->{pending_tasks} }, 0, 'permanent close_loser failure is not requeued even with retries available');

$m->{state}{positions}{'c1:YES'}{queued}{redeem} = JSON::PP::true;
$m->_retry_or_clear({ action => 'redeem', position_key => 'c1:YES', retries => 0 }, 'No wallet configured. Run `polymarket wallet create`');
ok($m->{state}{positions}{'c1:YES'}{done}{redeem}, 'redeem marked done on permanent wallet-misconfig failure');
ok(!$m->{state}{positions}{'c1:YES'}{queued}{redeem}, 'queued redeem cleared after give up');
is(scalar @{ $m->{pending_tasks} }, 0, 'permanent wallet failure does not enqueue retry');

$m->{state}{positions}{'c1:YES'}{queued}{tp1} = JSON::PP::true;
$m->_retry_or_clear({ action => 'tp1', position_key => 'c1:YES', retries => 0 }, 'temporary network error');
is(scalar @{ $m->{pending_tasks} }, 1, 'non-permanent failures still retry');
is($m->{pending_tasks}[0]{retries}, 1, 'retry counter incremented for non-permanent failure');

done_testing();
