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

            worker_count      => _env_num('WORKER_COUNT', 2),
            worker_timeout_s  => _env_num('WORKER_TIMEOUT_S', 30),
            worker_max_retries => _env_num('WORKER_MAX_RETRIES', 2),
            loser_sweep_to    => ($ENV{LOSER_SWEEP_TO} // ''),
            result_dir        => ($ENV{RESULT_DIR} // '/tmp/polyman-results'),
        },
        pending_tasks  => [],
        active_workers => {},
        last_snapshot  => {},
    };

    bless $self, $class;

    $self->{positions_api} = Positions->new(
        signature_type => $self->{cfg}{signature_type},
        page_size      => $self->{cfg}{page_size},
    );
    $self->{wallet} = _env_wallet_override();
    $self->{state}  = $self->load_state();
    $self->{state}{positions} ||= {};
    $self->_reset_orphaned_queued_state();

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

sub _env_wallet_override {
    return $ENV{WALLET_ADDRESS} if defined $ENV{WALLET_ADDRESS} && $ENV{WALLET_ADDRESS} =~ /^0x[0-9a-fA-F]{40}$/;
    return undef;
}

sub _mkdir_p {
    my ($dir) = @_;
    return unless defined $dir && length $dir;
    return if -d $dir;
    system('mkdir', '-p', $dir);
}

sub _num_or_undef {
    my ($v) = @_;
    return undef unless defined $v;
    return undef unless $v =~ /^-?\d+(?:\.\d+)?$/;
    return $v + 0;
}

sub _looks_like_loser {
    my ($self, $p) = @_;
    return 0 unless ref($p) eq 'HASH';

    my $pp = _num_or_undef($p->{percent_pnl});
    return 1 if defined($pp) && $pp <= -99;

    my $cv = _num_or_undef($p->{current_value});
    my $cp = _num_or_undef($p->{cur_price});
    return 1 if defined($cv) && $cv == 0 && defined($cp) && $cp == 0;

    return 0;
}

sub poll_interval_s { return $_[0]{cfg}{poll_interval_s}; }
sub wallet          { return $_[0]{wallet}; }

sub _ensure_wallet {
    my ($self) = @_;
    return $self->{wallet} if defined $self->{wallet} && $self->{wallet} ne '';

    my $wallet = eval { $self->{positions_api}->wallet_address() };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        $self->log_line("WARN: wallet unavailable: $err");
        return undef;
    }

    $self->{wallet} = $wallet;
    $self->log_line("Wallet detected: $wallet");
    return $wallet;
}

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


sub _reset_orphaned_queued_state {
    my ($self) = @_;

    my $positions = $self->{state}{positions} || {};
    my $reset = 0;

    for my $key (keys %$positions) {
        my $s = $positions->{$key};
        next unless ref($s) eq 'HASH';

        $s->{queued} ||= {};
        $s->{done} ||= {};

        next unless ref($s->{queued}) eq 'HASH';
        next unless keys %{ $s->{queued} };

        $s->{queued} = {};
        $reset++;
    }

    if ($reset > 0) {
        $self->log_line("WARN: cleared orphaned queued flags for $reset positions after startup");
    }
}

sub _task_is_busy {
    my ($self, $s, $action) = @_;
    return 1 if $s->{queued}{$action};
    return 0;
}

sub _pending_has_task {
    my ($self, $task) = @_;
    for my $t (@{ $self->{pending_tasks} }) {
        next unless ($t->{position_key} // '') eq ($task->{position_key} // '');
        next unless ($t->{action} // '') eq ($task->{action} // '');
        return 1;
    }
    return 0;
}

sub _position_has_inflight_task {
    my ($self, $position_key) = @_;
    return 0 unless defined $position_key;

    for my $task (@{ $self->{pending_tasks} || [] }) {
        return 1 if ($task->{position_key} // '') eq $position_key;
    }

    for my $pid (keys %{ $self->{active_workers} || {} }) {
        my $task = $self->{active_workers}{$pid}{task} || {};
        return 1 if ($task->{position_key} // '') eq $position_key;
    }

    return 0;
}

sub enqueue_task {
    my ($self, %task) = @_;
    return if $self->_pending_has_task(\%task);
    push @{ $self->{pending_tasks} }, \%task;
}

sub _build_task {
    my ($self, %args) = @_;
    return {
        action        => $args{action},
        position_key  => $args{position_key},
        token_dec     => $args{token_dec},
        amount        => $args{amount},
        condition_id  => $args{condition_id},
        retries       => ($args{retries} // 0),
    };
}

sub _queued_sell_amount_for_position {
    my ($self, $position_key) = @_;
    my $queued = 0;

    for my $task (@{ $self->{pending_tasks} || [] }) {
        next unless ($task->{position_key} // '') eq $position_key;
        next unless ($task->{action} // '') eq 'tp1' || ($task->{action} // '') eq 'tp2';
        my $amount = _num_or_undef($task->{amount});
        $queued += $amount if defined $amount && $amount > 0;
    }

    for my $pid (keys %{ $self->{active_workers} || {} }) {
        my $task = $self->{active_workers}{$pid}{task} || {};
        next unless ($task->{position_key} // '') eq $position_key;
        next unless ($task->{action} // '') eq 'tp1' || ($task->{action} // '') eq 'tp2';
        my $amount = _num_or_undef($task->{amount});
        $queued += $amount if defined $amount && $amount > 0;
    }

    return $queued;
}

sub _child_result_path {
    my ($self, $pid) = @_;
    return $self->{cfg}{result_dir} . "/$pid.json";
}

sub _position_snapshot {
    my ($self, $positions) = @_;
    my %snap;
    for my $p (@$positions) {
        next unless ref($p) eq 'HASH';
        my $key = $self->position_key($p);
        $snap{$key} = {
            size        => _num_or_undef($p->{size}),
            current_value => _num_or_undef($p->{current_value}),
            redeemable  => ($p->{redeemable} ? 1 : 0),
        };
    }
    return \%snap;
}

sub _task_has_progress {
    my ($self, $task, $before, $after) = @_;
    my $k = $task->{position_key};
    my $b = $before->{$k};
    my $a = $after->{$k};

    # A missing position in the latest snapshot is ambiguous (temporary API omission
    # or external close) and must not be treated as worker progress.
    return 0 if !$a;

    my $action = $task->{action} // '';
    if ($action eq 'redeem') {
        return 1 if $b && ($b->{redeemable} // 0) && !($a->{redeemable} // 0);
        return 0;
    }

    my $bs = defined($b) ? ($b->{size} // undef) : undef;
    my $as = $a->{size};
    return 1 if defined($bs) && defined($as) && $as < $bs;

    my $bcv = defined($b) ? ($b->{current_value} // undef) : undef;
    my $acv = $a->{current_value};
    return 1 if defined($bcv) && defined($acv) && $acv < $bcv;

    return 0;
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
    }
    elsif ($task->{action} eq 'close_loser') {
        $res = $api->close_zero_value_position(
            token_dec    => $task->{token_dec},
            amount       => $task->{amount},
            condition_id => $task->{condition_id},
            sweep_to     => $self->{cfg}{loser_sweep_to},
        );
    }
    else {
        $res = $api->market_sell(token_dec => $task->{token_dec}, amount => $task->{amount});
    }

    my $payload = {
        task  => $task,
        ok    => $res->{ok} ? JSON::PP::true : JSON::PP::false,
        error => $res->{error},
        ts    => now_utc(),
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

        $self->{active_workers}{$pid} = {
            task       => $task,
            started_at => time(),
            baseline   => $self->{last_snapshot},
        };
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
    my $ok = $result->{ok} ? 1 : 0;
    delete $s->{queued}{$action} if $ok;

    if ($ok && $action eq 'tp1') { $s->{tp1_done} = JSON::PP::true; }
    if ($ok && $action eq 'tp2') { $s->{tp2_done} = JSON::PP::true; }

    if ($ok && ($action eq 'stop_hit'
        || $action eq 'max_loss'
        || $action eq 'redeem'
        || $action eq 'close_loser')) {
        $s->{done} ||= {};
        $s->{done}{$action} = JSON::PP::true;
    }
}

sub _is_permanent_task_failure {
    my ($self, $action, $reason) = @_;
    my $r = lc(($reason // ''));

    return 1 if $action eq 'close_loser' && $r =~ /unable to close zero value position/;
    return 1 if $r =~ /no wallet configured/;

    return 0;
}

sub _retry_or_clear {
    my ($self, $task, $reason) = @_;
    my $key = $task->{position_key};
    my $action = $task->{action};

    my $retry = ($task->{retries} // 0) + 1;
    if ($retry <= $self->{cfg}{worker_max_retries}) {
        my %new = %$task;
        $new{retries} = $retry;
        $self->enqueue_task(%new);
        $self->log_line("WARN: retry task action=$action key=$key retry=$retry reason=$reason");
        return;
    }

    if (defined $key && exists $self->{state}{positions}{$key}) {
        delete $self->{state}{positions}{$key}{queued}{$action};
        if ($self->_is_permanent_task_failure($action, $reason)) {
            $self->{state}{positions}{$key}{done} ||= {};
            $self->{state}{positions}{$key}{done}{$action} = JSON::PP::true;
        }
    }
    $self->log_line("ERR: giving up task action=$action key=$key reason=$reason");
}

sub reap_workers {
    my ($self) = @_;

    while (1) {
        my $pid = waitpid(-1, WNOHANG);
        last if $pid <= 0;

        my $meta = delete $self->{active_workers}{$pid};
        next unless $meta;
        my $task = $meta->{task};

        my $path = $self->_child_result_path($pid);
        if (-f $path) {
            open my $fh, '<', $path;
            my $raw = do { local $/; <$fh> };
            close $fh;
            unlink $path;

            my $decoded = eval { JSON::PP->new->utf8->decode($raw) };
            if (!$@ && ref($decoded) eq 'HASH') {
                $self->_apply_task_result($decoded);
                if ($decoded->{ok}) {
                    $self->log_line("INFO: task done action=$task->{action} key=$task->{position_key}");
                }
                else {
                    $self->_retry_or_clear($task, $decoded->{error} // 'worker failed');
                }
            }
            else {
                $self->_retry_or_clear($task, 'bad worker payload');
            }
        }
        else {
            $self->_retry_or_clear($task, 'missing worker result');
        }
    }
}

sub monitor_stalled_workers {
    my ($self, $snapshot) = @_;

    my $timeout = $self->{cfg}{worker_timeout_s};
    return if $timeout <= 0;

    for my $pid (keys %{ $self->{active_workers} }) {
        my $meta = $self->{active_workers}{$pid};
        my $age = time() - ($meta->{started_at} // time());
        next if $age < $timeout;

        my $task = $meta->{task};
        my $baseline = $meta->{baseline} || {};
        my $has_progress = $self->_task_has_progress($task, $baseline, $snapshot);
        if ($has_progress) {
            $meta->{started_at} = time();
            $meta->{baseline}   = $snapshot;
            $self->log_line("INFO: worker pid=$pid still progressing action=$task->{action} key=$task->{position_key}");
            next;
        }

        $self->log_line("WARN: worker pid=$pid stalled action=$task->{action} key=$task->{position_key}, killing");
        kill 'TERM', $pid;
        waitpid($pid, WNOHANG);
        kill 'KILL', $pid;
        waitpid($pid, WNOHANG);

        delete $self->{active_workers}{$pid};
        $self->_retry_or_clear($task, 'stalled worker');
    }
}

sub _queue_position_tasks {
    my ($self, $p, $s, $key, $ts) = @_;

    my $size        = $p->{size};
    my $token_dec   = $self->_resolve_token_dec($p);
    my $percent_pnl = $p->{percent_pnl};

    if (($self->{cfg}{tp1_trigger_pct} + 0) > 0
        && ($self->{cfg}{tp1_close_pct} + 0) > 0
        && !$s->{tp1_done}
        && !$self->_task_is_busy($s, 'tp1')
        && ($percent_pnl + 0) >= ($self->{cfg}{tp1_trigger_pct} + 0)) {
        my $sell_amount = ($size + 0) * (($self->{cfg}{tp1_close_pct} + 0) / 100);
        if ($sell_amount > 0) {
            my $task = $self->_build_task(action => 'tp1', position_key => $key, token_dec => $token_dec, amount => sprintf('%.8f', $sell_amount));
            $self->enqueue_task(%$task);
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
            my $task = $self->_build_task(action => 'tp2', position_key => $key, token_dec => $token_dec, amount => sprintf('%.8f', $sell_amount));
            $self->enqueue_task(%$task);
            $s->{queued}{tp2} = JSON::PP::true;
        }
    }

    if (($self->{cfg}{max_loss_pct} + 0) > 0
        && !$self->_task_is_busy($s, 'max_loss')
        && !($s->{done}{max_loss} ? 1 : 0)
        && ($percent_pnl + 0) <= -($self->{cfg}{max_loss_pct} + 0)) {
        my $task = $self->_build_task(action => 'max_loss', position_key => $key, token_dec => $token_dec, amount => $size);
        $self->enqueue_task(%$task);
        $s->{queued}{max_loss} = JSON::PP::true;
        return;
    }

    if ($ts->{stop_hit} && !$self->_task_is_busy($s, 'stop_hit') && !($s->{done}{stop_hit} ? 1 : 0)) {
        my $remaining_size = ($size + 0) - $self->_queued_sell_amount_for_position($key);
        if ($remaining_size > 0) {
            my $task = $self->_build_task(
                action       => 'stop_hit',
                position_key => $key,
                token_dec    => $token_dec,
                amount       => sprintf('%.8f', $remaining_size),
            );
            $self->enqueue_task(%$task);
            $s->{queued}{stop_hit} = JSON::PP::true;
        }
        return;
    }
}

sub run_iteration {
    my ($self) = @_;

    $self->reap_workers();

    my $wallet = $self->_ensure_wallet();
    my $positions = [];
    if (defined $wallet && $wallet ne '') {
        $positions = $self->{positions_api}->fetch_positions($wallet);
    }

    my $snapshot = $self->_position_snapshot($positions);
    $self->{last_snapshot} = $snapshot;
    $self->monitor_stalled_workers($snapshot);

    return unless defined $wallet && $wallet ne '';

    my %seen;

    for my $p (@$positions) {
        next unless ref($p) eq 'HASH';
        my $size = _num_or_undef($p->{size});
        next unless defined $size && $size > 0;

        my $key = $self->position_key($p);
        $seen{$key} = 1;

        $self->{state}{positions}{$key} ||= {
            tp1_done => JSON::PP::false,
            tp2_done => JSON::PP::false,
            queued   => {},
            done     => {},
        };
        my $s = $self->{state}{positions}{$key};
        $s->{queued} ||= {};
        $s->{done} ||= {};

        my $current_value = _num_or_undef($p->{current_value});
        my $token_dec = $self->_resolve_token_dec($p);
        my $has_token_dec = _is_token_id($token_dec);

        if ($self->{cfg}{close_on_redeemable}
            && ($p->{redeemable} ? 1 : 0)
            && !$self->_looks_like_loser($p)
            && !$self->_task_is_busy($s, 'redeem')
            && !($s->{done}{redeem} ? 1 : 0)) {
            my $task = $self->_build_task(action => 'redeem', position_key => $key, condition_id => $p->{condition_id});
            $self->enqueue_task(%$task);
            $s->{queued}{redeem} = JSON::PP::true;
            next;
        }

        if (defined $current_value
            && $current_value <= 0
            && !$self->_task_is_busy($s, 'close_loser')
            && !($s->{done}{close_loser} ? 1 : 0)) {
            my $task = $self->_build_task(
                action       => 'close_loser',
                position_key => $key,
                token_dec    => ($has_token_dec ? $token_dec : undef),
                amount       => $size,
                condition_id => $p->{condition_id},
            );
            $self->enqueue_task(%$task);
            $s->{queued}{close_loser} = JSON::PP::true;
            next;
        }

        next unless $has_token_dec;

        # trailing stop is only for open/active positions still with value.
        if (defined $current_value && $current_value > 0) {
            my $percent_pnl = $p->{percent_pnl};
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
    }

    for my $k (keys %{ $self->{state}{positions} }) {
        next if $seen{$k};
        next if $self->_position_has_inflight_task($k);
        delete $self->{state}{positions}{$k};
    }

    $self->dispatch_workers();
    $self->save_state();
}

sub _resolve_token_dec {
    my ($self, $p) = @_;

    my $api = $self->{positions_api};
    if ($api && $api->can('token_dec_for_position')) {
        return $api->token_dec_for_position($p);
    }

    return undef unless ref($p) eq 'HASH';
    for my $k (qw(asset_id token_id clob_token_id)) {
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

1;
