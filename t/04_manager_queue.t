use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);

use lib 't/lib';
use lib 'lib';

use JSON::PP ();
use Manager;

my $tmp = tempdir(CLEANUP => 1);

my $m = bless {
    cfg => {
        worker_count => 2,
        result_dir => $tmp,
        signature_type => '',
        page_size => 10,
        tp1_trigger_pct => 5,
        tp1_close_pct => 10,
        tp2_trigger_pct => 0,
        tp2_close_pct => 0,
        max_loss_pct => 0,
        close_on_redeemable => 0,
    },
    state => {
        positions => {
            'k1' => { queued => { tp1 => JSON::PP::true }, tp1_done => JSON::PP::false },
            'k2' => { queued => { tp1 => JSON::PP::true }, tp1_done => JSON::PP::false },
            'k3' => { queued => { tp1 => JSON::PP::true }, tp1_done => JSON::PP::false },
        }
    },
    pending_tasks => [
        { action => 'tp1', position_key => 'k1', token_dec => '1', amount => '1' },
        { action => 'tp1', position_key => 'k2', token_dec => '2', amount => '1' },
        { action => 'tp1', position_key => 'k3', token_dec => '3', amount => '1' },
    ],
    active_workers => {},
}, 'Manager';

{
    no warnings 'redefine';
    local *Manager::_run_task_in_child = sub {
        my ($self, $task) = @_;
        sleep(0.05);
        my $payload = { task => $task, ok => JSON::PP::true, ts => 'now' };
        open my $fh, '>', $self->_child_result_path($$) or exit 2;
        print $fh JSON::PP->new->encode($payload);
        close $fh;
        exit 0;
    };

    $m->dispatch_workers();
    is(scalar(keys %{ $m->{active_workers} }), 2, 'starts up to worker_count workers');
    is(scalar(@{ $m->{pending_tasks} }), 1, 'one task stays queued');

    for (1..50) {
        $m->reap_workers();
        last if scalar(keys %{ $m->{active_workers} }) == 0;
        sleep(0.02);
    }
    is(scalar(keys %{ $m->{active_workers} }), 0, 'workers reaped and no zombies tracked');

    $m->dispatch_workers();
    is(scalar(keys %{ $m->{active_workers} }), 1, 'remaining task dispatched');

    for (1..50) {
        $m->reap_workers();
        last if scalar(keys %{ $m->{active_workers} }) == 0;
        sleep(0.02);
    }

    is(scalar(@{ $m->{pending_tasks} }), 0, 'all tasks processed');
    ok($m->{state}{positions}{k1}{tp1_done}, 'k1 tp1 marked done');
    ok($m->{state}{positions}{k2}{tp1_done}, 'k2 tp1 marked done');
    ok($m->{state}{positions}{k3}{tp1_done}, 'k3 tp1 marked done');

    ok(!$m->{state}{positions}{k1}{queued}{tp1}, 'queued flag cleared k1');
}

# duplicate queue prevention for same job in same cycle
my $s = { queued => {}, tp1_done => JSON::PP::false, tp2_done => JSON::PP::false };
my $p = { size => 10, asset_id => '123', percent_pnl => 20, redeemable => JSON::PP::false, condition_id => 'c1' };
my $ts = { stop_hit => 0 };

$m->{pending_tasks} = [];
$m->_queue_position_tasks($p, $s, 'dup:key', $ts);
$m->_queue_position_tasks($p, $s, 'dup:key', $ts);

is(scalar(@{ $m->{pending_tasks} }), 1, 'same tp1 job not queued twice while queued flag set');

# cleanup any stragglers to release resources
for (1..20) {
    my $pid = waitpid(-1, 1);
    last if $pid <= 0;
}

done_testing();
