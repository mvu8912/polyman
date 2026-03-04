package Manager;
use strict;
use warnings;

use JSON::PP ();
use POSIX qw(strftime WNOHANG);

use Positions;
use TrailingStop;

sub new_from_env {
    my ($class) = @_;

    my $self = {
        cfg => {
            poll_interval_s => _env_num('POLL_INTERVAL_S', 2),
            state_file      => ($ENV{STATE_FILE} // '/data/manager-state.json'),
            page_size       => _env_num('PAGE_SIZE', 200),
            signature_type  => ($ENV{SIGNATURE_TYPE} // ''),

            max_loss_pct     => _env_num('MAX_LOSS_PCT', 0),
            sl_set_to        => _env_num('SL_SET_TO', 10),
            ts_trigger_at    => _env_num('TS_TRIGGER_AT', 5),
            ts_move_each     => _env_num('TS_MOVE_EACH', 5),

            tp1_trigger_pct  => _env_num('TP1_TRIGGER_PCT', 0),
            tp1_close_pct    => _env_num('TP1_CLOSE_PCT', 0),
            tp2_trigger_pct  => _env_num('TP2_TRIGGER_PCT', 0),
            tp2_close_pct    => _env_num('TP2_CLOSE_PCT', 0),

            close_on_redeemable => _env_bool('CLOSE_ON_REDEEMABLE', 1),

            worker_count => _env_num('WORKER_COUNT', 2),
            result_dir   => ($ENV{RESULT_DIR} // '/tmp/polyman-results'),
        },
        pending_tasks => [],
        active_workers => {},
    };

    bless $self, $class;

    $self->{positions_api} = Positions->new(
        signature_type => $self->{cfg}{signature_type},
        page_size      => $self->{cfg}{page_size},
    );
    $self->{wallet} = $self->{positions_api}->wallet_address();
    $self->{state}  = $self->load_state();
    $self->{state}{positions} ||= {};

    _mkdir_p($self->{cfg}{result_dir});

    return $self;
}

sub _env_num {
    my ($k, $default) = @_;
    return $default unless defined $ENV{$k} && $ENV{$k} ne '';
    return 0 + $ENV{$k};
}

sub _env_bool {
    my ($k, $default) = @_;
    return $default unless defined $ENV{$k};
    my $v = lc($ENV{$k});
    return 1 if $v eq '1' || $v eq 'true' || $v eq 'yes';
    return 0;
}

sub _mkdir_p {
    my ($dir) = @_;
    return unless defined $dir && length $dir;
    return if -d $dir;
    system('mkdir', '-p', $dir);
}

sub poll_interval_s { return $_[0]{cfg}{poll_interval_s}; }
sub wallet          { return $_[0]{wallet}; }

sub now_utc { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()) }

sub log_line {
    my ($self, $msg) = @_;
    print '[' . now_utc() . "] $msg\n";
}

sub position_key {
    my ($self, $p) = @_;
    return join(':', ($p->{condition_id} // 'none'), ($p->{outcome} // 'none'));
}

sub load_state {
    my ($self) = @_;
    my $path = $self->{cfg}{state_file};
    return {} unless -f $path;

    open my $fh, '<', $path or die "Cannot read state file $path: $!\n";
    my $raw = do { local $/; <$fh> };
    close $fh;

    my $obj = eval { JSON::PP->new->utf8->decode($raw) };
    if ($@ || ref($obj) ne 'HASH') {
        $self->log_line("WARN: invalid state file, resetting: $path");
        return {};
    }
    return $obj;
}

sub save_state {
    my ($self) = @_;
    my $path = $self->{cfg}{state_file};

    my $dir = $path;
    $dir =~ s{/[^/]+$}{};
    _mkdir_p($dir);

    my $tmp = $path . '.tmp';
    open my $fh, '>', $tmp or die "Cannot write state tmp $tmp: $!\n";
    print $fh JSON::PP->new->utf8->canonical->pretty->encode($self->{state});
    close $fh;
    rename $tmp, $path or die "Cannot move state tmp into place: $!\n";
}

sub _task_is_busy {
    my ($self, $s, $action) = @_;
    return 1 if $s->{queued}{$action};
    return 0;
}

sub enqueue_task {
    my ($self, %task) = @_;
    push @{ $self->{pending_tasks} }, \%task;
}

sub _build_task {
    my ($self, %args) = @_;
    return {
        action    => $args{action},
        position_key => $args{position_key},
        token_dec => $args{token_dec},
        amount    => $args{amount},
        condition_id => $args{condition_id},
    };
}

sub _child_result_path {
    my ($self, $pid) = @_;
    return $self->{cfg}{result_dir} . "/$pid.json";
}

sub _run_task_in_child {
    my ($self, $task) = @_;

    my $api = Positions->new(
        signature_type => $self->{cfg}{signature_type},
        page_size      => $self->{cfg}{page_size},
    );

    my $res;
    if ($task->{action} eq 'redeem') {
        $res = $api->redeem_condition(condition_id => $task->{condition_id});
    } else {
        $res = $api->market_sell(token_dec => $task->{token_dec}, amount => $task->{amount});
    }

    my $payload = {
        task => $task,
        ok   => $res->{ok} ? JSON::PP::true : JSON::PP::false,
        error => $res->{error},
        ts   => now_utc(),
    };

    my $path = $self->_child_result_path($$);
    open my $fh, '>', $path or exit 2;
    print $fh JSON::PP->new->utf8->canonical->encode($payload);
    close $fh;
    exit($res->{ok} ? 0 : 1);
}

sub dispatch_workers {
    my ($self) = @_;

    my $limit = $self->{cfg}{worker_count};
    $limit = 1 if $limit < 1;

    while (@{ $self->{pending_tasks} } && scalar(keys %{ $self->{active_workers} }) < $limit) {
        my $task = shift @{ $self->{pending_tasks} };
        my $pid = fork();

        if (!defined $pid) {
            $self->log_line("ERR: fork failed for task action=$task->{action} key=$task->{position_key}");
            unshift @{ $self->{pending_tasks} }, $task;
            last;
        }

        if ($pid == 0) {
            $self->_run_task_in_child($task);
        }

        $self->{active_workers}{$pid} = $task;
        $self->log_line("INFO: dispatched worker pid=$pid action=$task->{action} key=$task->{position_key}");
    }
}

sub _apply_task_result {
    my ($self, $result) = @_;
    my $task = $result->{task} || {};
    my $key = $task->{position_key};
    return unless defined $key && exists $self->{state}{positions}{$key};

    my $s = $self->{state}{positions}{$key};
    my $action = $task->{action} // '';
    delete $s->{queued}{$action};

    my $ok = $result->{ok} ? 1 : 0;
    if ($ok && $action eq 'tp1') {
        $s->{tp1_done} = JSON::PP::true;
    }
    if ($ok && $action eq 'tp2') {
        $s->{tp2_done} = JSON::PP::true;
    }
}

sub reap_workers {
    my ($self) = @_;

    while (1) {
        my $pid = waitpid(-1, WNOHANG);
        last if $pid <= 0;

        my $task = delete $self->{active_workers}{$pid};
        next unless $task;

        my $path = $self->_child_result_path($pid);
        if (-f $path) {
            open my $fh, '<', $path;
            my $raw = do { local $/; <$fh> };
            close $fh;
            unlink $path;

            my $decoded = eval { JSON::PP->new->utf8->decode($raw) };
            if (!$@ && ref($decoded) eq 'HASH') {
                $self->_apply_task_result($decoded);
                $self->log_line(($decoded->{ok} ? 'INFO' : 'ERR') . ": task done action=$task->{action} key=$task->{position_key}");
            }
        }
    }
}

sub _queue_position_tasks {
    my ($self, $p, $s, $key, $ts) = @_;

    my $size        = $p->{size};
    my $token_dec   = $p->{asset_id};
    my $percent_pnl = $p->{percent_pnl};

    if (($self->{cfg}{tp1_trigger_pct} + 0) > 0
        && ($self->{cfg}{tp1_close_pct} + 0) > 0
        && !$s->{tp1_done}
        && !$self->_task_is_busy($s, 'tp1')
        && ($percent_pnl + 0) >= ($self->{cfg}{tp1_trigger_pct} + 0)) {
        my $sell_amount = ($size + 0) * (($self->{cfg}{tp1_close_pct} + 0) / 100);
        if ($sell_amount > 0) {
            $self->enqueue_task(%{ $self->_build_task(action => 'tp1', position_key => $key, token_dec => $token_dec, amount => sprintf('%.8f', $sell_amount)) });
            $s->{queued}{tp1} = JSON::PP::true;
        }
    }

    if (($self->{cfg}{tp2_trigger_pct} + 0) > 0
        && ($self->{cfg}{tp2_close_pct} + 0) > 0
        && !$s->{tp2_done}
        && !$self->_task_is_busy($s, 'tp2')
        && ($percent_pnl + 0) >= ($self->{cfg}{tp2_trigger_pct} + 0)) {
        my $sell_amount = ($size + 0) * (($self->{cfg}{tp2_close_pct} + 0) / 100);
        if ($sell_amount > 0) {
            $self->enqueue_task(%{ $self->_build_task(action => 'tp2', position_key => $key, token_dec => $token_dec, amount => sprintf('%.8f', $sell_amount)) });
            $s->{queued}{tp2} = JSON::PP::true;
        }
    }

    if (($self->{cfg}{max_loss_pct} + 0) > 0
        && !$self->_task_is_busy($s, 'max_loss')
        && ($percent_pnl + 0) <= -($self->{cfg}{max_loss_pct} + 0)) {
        $self->enqueue_task(%{ $self->_build_task(action => 'max_loss', position_key => $key, token_dec => $token_dec, amount => $size) });
        $s->{queued}{max_loss} = JSON::PP::true;
        return;
    }

    if ($ts->{stop_hit} && !$self->_task_is_busy($s, 'stop_hit')) {
        $self->enqueue_task(%{ $self->_build_task(action => 'stop_hit', position_key => $key, token_dec => $token_dec, amount => $size) });
        $s->{queued}{stop_hit} = JSON::PP::true;
        return;
    }

    if ($self->{cfg}{close_on_redeemable}
        && ($p->{redeemable} ? 1 : 0)
        && !$self->_task_is_busy($s, 'redeem')) {
        $self->enqueue_task(%{ $self->_build_task(action => 'redeem', position_key => $key, condition_id => $p->{condition_id}) });
        $s->{queued}{redeem} = JSON::PP::true;
    }
}

sub run_iteration {
    my ($self) = @_;

    $self->reap_workers();

    my $positions = $self->{positions_api}->fetch_positions($self->{wallet});
    my %seen;

    for my $p (@$positions) {
        next unless ref($p) eq 'HASH';
        my $size = $p->{size};
        next unless defined $size && $size =~ /^\d+(?:\.\d+)?$/;
        next if ($size + 0) <= 0;

        my $key = $self->position_key($p);
        $seen{$key} = 1;

        $self->{state}{positions}{$key} ||= {
            tp1_done => JSON::PP::false,
            tp2_done => JSON::PP::false,
            queued   => {},
        };
        my $s = $self->{state}{positions}{$key};
        $s->{queued} ||= {};

        my $percent_pnl = $p->{percent_pnl};
        my $token_dec   = $p->{asset_id};

        next unless defined $token_dec && $token_dec =~ /^\d+$/;

        my $ts = TrailingStop::evaluate_position(
            position => $p,
            state    => $s,
            cfg      => {
                sl_set_to     => $self->{cfg}{sl_set_to},
                ts_trigger_at => $self->{cfg}{ts_trigger_at},
                ts_move_each  => $self->{cfg}{ts_move_each},
            },
        );
        next unless $ts->{valid};

        if ($ts->{moved}) {
            $self->log_line("TS move key=$key pnl=$percent_pnl stop=" . sprintf('%.6f', $ts->{stop_price}));
        }

        $self->_queue_position_tasks($p, $s, $key, $ts);
    }

    for my $k (keys %{ $self->{state}{positions} }) {
        delete $self->{state}{positions}{$k} unless $seen{$k};
    }

    $self->dispatch_workers();
    $self->save_state();
}

1;
