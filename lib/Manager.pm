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
            redeem_retry_cooldown_s => _env_num('REDEEM_RETRY_COOLDOWN_S', 300),
            loser_sweep_to    => ($ENV{LOSER_SWEEP_TO} // ''),
            result_dir        => ($ENV{RESULT_DIR} // '/tmp/polyman-results'),
            post_action_verify_timeout_s  => _env_num('POST_ACTION_VERIFY_TIMEOUT_S', 60),
            post_action_verify_interval_s => _env_num('POST_ACTION_VERIFY_INTERVAL_S', 5),
        },
        pending_tasks  => [],
        active_workers => {},
        last_snapshot  => {},
    };

    bless $self, $class;

    $self->{positions_api} = Positions->new(
        signature_type => $self->{cfg}{signature_type},
        page_size      => $self->{cfg}{page_size},
        private_key    => ($ENV{PRIVATE_KEY} // ''),
        wallet_address => ($ENV{WALLET_ADDRESS} // ''),
    );
    $self->{wallet} = _env_wallet_override();
    $self->{state}  = $self->load_state();
    $self->{state}{positions} ||= {};
    $self->_reset_orphaned_queued_state();

    _mkdir_p($self->{cfg}{result_dir});
    $self->_log_wallet_env_summary();

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

sub _index_set_from_outcome_index {
    my ($idx) = @_;
    return undef unless defined $idx && $idx =~ /^\d+$/;
    return undef if $idx < 0 || $idx > 62;
    return 2 ** $idx;
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

sub _log_wallet_env_summary {
    my ($self) = @_;

    my $wallet = defined $ENV{WALLET_ADDRESS} ? 'set' : 'unset';
    my $pk = defined $ENV{PRIVATE_KEY} && $ENV{PRIVATE_KEY} ne '' ? 'set' : 'unset';
    my $sig = defined $self->{cfg}{signature_type} && $self->{cfg}{signature_type} ne '' ? $self->{cfg}{signature_type} : 'default';

    $self->log_line("INFO: wallet env summary wallet_address=$wallet private_key=$pk signature_type=$sig");
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

sub _json_compact {
    my ($v) = @_;
    my $txt = eval { JSON::PP->new->canonical->encode($v) };
    return '{}' if $@;
    $txt =~ s/\s+/ /g;
    $txt =~ s/^\s+|\s+$//g;
    return $txt;
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

sub _condition_redeem_busy_or_done {
    my ($self, $condition_id, $index_set) = @_;
    return 0 unless defined $condition_id && $condition_id ne '';

    my $same_scope = sub {
        my ($task) = @_;
        return 0 unless ref($task) eq 'HASH';
        return 0 unless (($task->{condition_id} // '') eq $condition_id);

        my $tidx = $task->{index_set};
        return 1 unless defined $index_set && $index_set =~ /^\d+$/;
        return 1 unless defined $tidx && $tidx =~ /^\d+$/;
        return $tidx == $index_set ? 1 : 0;
    };

    for my $task (@{ $self->{pending_tasks} || [] }) {
        next unless ($task->{action} // '') eq 'redeem';
        return 1 if $same_scope->($task);
    }

    for my $pid (keys %{ $self->{active_workers} || {} }) {
        my $task = $self->{active_workers}{$pid}{task} || {};
        next unless ($task->{action} // '') eq 'redeem';
        return 1 if $same_scope->($task);
    }

    return 0;
}

sub _has_active_redeem_worker {
    my ($self) = @_;
    for my $pid (keys %{ $self->{active_workers} || {} }) {
        my $task = $self->{active_workers}{$pid}{task} || {};
        return 1 if ($task->{action} // '') eq 'redeem';
    }
    return 0;
}

sub enqueue_task {
    my ($self, %task) = @_;
    return if $self->_pending_has_task(\%task);

    if (($task{action} // '') eq 'redeem') {
        return if $self->_condition_redeem_busy_or_done($task{condition_id}, $task{index_set});
    }

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
        index_set    => $args{index_set},
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

sub _summarize_task_error {
    my ($self, $res) = @_;
    return 'worker failed' unless ref($res) eq 'HASH';

    my $err = $res->{error};
    $err = '' unless defined $err;

    my $attempts = $res->{attempts};
    if (ref($attempts) eq 'ARRAY' && @$attempts) {
        my @parts;
        for my $a (@$attempts) {
            next unless ref($a) eq 'HASH';
            my $name = $a->{action} // 'unknown';
            my $ok = $a->{ok} ? 'ok' : 'fail';
            my $ae = $a->{error};
            $ae = '' unless defined $ae;
            $ae =~ s/\s+/ /g;
            $ae =~ s/^\s+|\s+$//g;
            push @parts, ($ae ne '' ? "$name:$ok:$ae" : "$name:$ok");
        }
        if (@parts) {
            my $suffix = join(' | ', @parts);
            return $err ne '' ? "$err [$suffix]" : $suffix;
        }
    }

    return $err ne '' ? $err : 'worker failed';
}

sub _task_position_gone {
    my ($self, $positions, $task) = @_;
    return 0 unless ref($positions) eq 'ARRAY' && ref($task) eq 'HASH';

    my $key = $task->{position_key};
    return 0 unless defined $key && $key ne '';

    my $action = $task->{action} // '';

    for my $p (@$positions) {
        next unless ref($p) eq 'HASH';
        next unless ($self->position_key($p) // '') eq $key;

        if ($action eq 'redeem') {
            my $redeemable = $p->{redeemable} ? 1 : 0;
            return $redeemable ? 0 : 1;
        }

        my $size = _num_or_undef($p->{size});
        return 1 if !defined($size) || $size <= 0;

        return 0;
    }

    return 1;
}


sub _fetch_manageable_positions {
    my ($self, $wallet) = @_;
    return [] unless defined $wallet && $wallet ne '';

    my $api = $self->{positions_api};
    if ($api && $api->can('fetch_manageable_positions')) {
        return $api->fetch_manageable_positions($wallet);
    }

    return $api->fetch_positions($wallet);
}


sub _verify_task_effect {
    my ($self, $api, $task) = @_;

    my $wallet = $self->{wallet};
    return (1, 'verify skipped: wallet unavailable') unless defined $wallet && $wallet ne '';

    my $timeout  = $self->{cfg}{post_action_verify_timeout_s} // 60;
    my $interval = $self->{cfg}{post_action_verify_interval_s} // 5;
    $timeout = 0 + $timeout;
    $interval = 0 + $interval;
    $interval = 1 if $interval < 1;

    my $deadline = time() + ($timeout > 0 ? $timeout : 0);
    my $attempt = 0;

    while (1) {
        $attempt++;
        my $positions = eval { $self->_fetch_manageable_positions($wallet) };
        if ($@) {
            my $e = $@;
            $e =~ s/\s+$//;
            return (0, "post-action verify fetch failed: $e");
        }

        if ($self->_task_position_gone($positions, $task)) {
            return (1, "verified position clear on attempt=$attempt");
        }

        last if $timeout <= 0 || time() >= $deadline;
        select(undef, undef, undef, $interval);
    }

    return (0, "post-action verify timeout after ${timeout}s: position still present key=" . ($task->{position_key} // 'unknown'));
}

sub _run_task_in_child {
    my ($self, $task) = @_;

    my $api = Positions->new(
        signature_type => $self->{cfg}{signature_type},
        page_size      => $self->{cfg}{page_size},
        private_key    => ($ENV{PRIVATE_KEY} // ''),
        wallet_address => ($ENV{WALLET_ADDRESS} // ''),
    );

    my $task_desc = JSON::PP->new->canonical->encode($task);
    $self->log_line("INFO: worker starting pid=$$ task=$task_desc");
    $self->log_line("INFO: worker wallet env pid=$$ wallet_address=" . (defined($ENV{WALLET_ADDRESS}) ? "set" : "unset") . " private_key=" . ((defined($ENV{PRIVATE_KEY}) && $ENV{PRIVATE_KEY} ne "") ? "set" : "unset"));

    my $exec = $self->_execute_task_with_recovery($api, $task);
    my $res = $exec->{res};
    my $ok = $exec->{ok};
    my $error = $exec->{error};
    my $verify_note = $exec->{verify_note};

    my $payload = {
        task        => $task,
        ok          => $ok ? JSON::PP::true : JSON::PP::false,
        error       => $error,
        verify_note => $verify_note,
        response    => $res->{response},
        attempts    => $res->{attempts},
        ts          => now_utc(),
    };

    my $path = $self->_child_result_path($$);
    open my $fh, '>', $path or exit 2;
    print $fh JSON::PP->new->utf8->canonical->encode($payload);
    close $fh;

    if ($ok) {
        $self->log_line("INFO: worker finished pid=$$ action=" . ($task->{action} // '') . " key=" . ($task->{position_key} // '') . " verify='" . ($verify_note // '') . "'");
    }
    else {
        $self->log_line("WARN: worker failed pid=$$ action=" . ($task->{action} // '') . " key=" . ($task->{position_key} // '') . " error='" . ($error // 'worker failed') . "'");
    }

    exit($ok ? 0 : 1);
}

sub _execute_task_with_recovery {
    my ($self, $api, $task) = @_;
    my $action = $task->{action} // '';

    my $res;
    if ($action eq 'redeem') {
        $res = $api->redeem_condition(condition_id => $task->{condition_id}, index_set => $task->{index_set});
    }
    elsif ($action eq 'close_loser') {
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

    my $ok = $res->{ok} ? 1 : 0;
    my $error = $ok ? undef : $self->_summarize_task_error($res);
    my $verify_note;

    if (!$ok && $action eq 'redeem') {
        if (defined($self->{cfg}{loser_sweep_to})
            && $self->{cfg}{loser_sweep_to} =~ /^0x[0-9a-fA-F]{40}$/
            && defined($task->{token_dec})) {
            my $sweep_res = $api->close_zero_value_position(
                token_dec    => $task->{token_dec},
                amount       => $task->{amount},
                condition_id => $task->{condition_id},
                sweep_to     => $self->{cfg}{loser_sweep_to},
                prefer_sweep => 1,
            );

            if ($sweep_res->{ok}) {
                my ($sweep_verified, $sweep_note) = $self->_verify_task_effect($api, $task);
                $verify_note = "redeem_failed_then_sweep: " . ($sweep_note // '');
                if ($sweep_verified) {
                    return {
                        ok          => 1,
                        error       => undef,
                        verify_note => $verify_note,
                        res         => { ok => JSON::PP::true, response => $sweep_res->{response}, attempts => [ { action => 'redeem', %$res }, { action => 'transfer', %$sweep_res } ] },
                    };
                }
                return {
                    ok          => 0,
                    error       => $sweep_note,
                    verify_note => $verify_note,
                    res         => { ok => JSON::PP::false, attempts => [ { action => 'redeem', %$res }, { action => 'transfer', %$sweep_res } ] },
                };
            }

            return {
                ok          => 0,
                error       => $self->_summarize_task_error($sweep_res),
                verify_note => undef,
                res         => { ok => JSON::PP::false, attempts => [ { action => 'redeem', %$res }, { action => 'transfer', %$sweep_res } ] },
            };
        }
    }

    if (!$ok && ($action eq 'tp1' || $action eq 'tp2' || $action eq 'stop_hit' || $action eq 'max_loss')) {
        if (defined($task->{condition_id}) && $task->{condition_id} ne '') {
            my $redeem_res = $api->redeem_condition(condition_id => $task->{condition_id}, index_set => $task->{index_set});
            if ($redeem_res->{ok}) {
                my ($redeem_verified, $redeem_note) = $self->_verify_task_effect($api, $task);
                $verify_note = "sell_failed_then_redeem: " . ($redeem_note // '');
                if ($redeem_verified) {
                    return {
                        ok         => 1,
                        error      => undef,
                        verify_note=> $verify_note,
                        res        => { ok => JSON::PP::true, response => $redeem_res->{response}, attempts => [ { action => 'sell', %$res }, { action => 'redeem', %$redeem_res } ] },
                    };
                }

                return {
                    ok          => 0,
                    error       => $redeem_note,
                    verify_note => $verify_note,
                    res         => { ok => JSON::PP::false, attempts => [ { action => 'sell', %$res }, { action => 'redeem', %$redeem_res } ] },
                };
            }

            if (defined($self->{cfg}{loser_sweep_to})
                && $self->{cfg}{loser_sweep_to} =~ /^0x[0-9a-fA-F]{40}$/
                && defined($task->{token_dec})
                && defined($task->{amount})) {
                my $sweep_res = $api->close_zero_value_position(
                    token_dec    => $task->{token_dec},
                    amount       => $task->{amount},
                    condition_id => $task->{condition_id},
                    sweep_to     => $self->{cfg}{loser_sweep_to},
                    prefer_sweep => 1,
                );
                if ($sweep_res->{ok}) {
                    my ($sweep_verified, $sweep_note) = $self->_verify_task_effect($api, $task);
                    $verify_note = "sell_redeem_failed_then_sweep: " . ($sweep_note // '');
                    if ($sweep_verified) {
                        return {
                            ok          => 1,
                            error       => undef,
                            verify_note => $verify_note,
                            res         => { ok => JSON::PP::true, response => $sweep_res->{response}, attempts => [ { action => 'sell', %$res }, { action => 'redeem', %$redeem_res }, { action => 'transfer', %$sweep_res } ] },
                        };
                    }
                    return {
                        ok          => 0,
                        error       => $sweep_note,
                        verify_note => $verify_note,
                        res         => { ok => JSON::PP::false, attempts => [ { action => 'sell', %$res }, { action => 'redeem', %$redeem_res }, { action => 'transfer', %$sweep_res } ] },
                    };
                }

                return {
                    ok          => 0,
                    error       => $self->_summarize_task_error($sweep_res),
                    verify_note => undef,
                    res         => { ok => JSON::PP::false, attempts => [ { action => 'sell', %$res }, { action => 'redeem', %$redeem_res }, { action => 'transfer', %$sweep_res } ] },
                };
            }
        }
    }

    if ($ok) {
        my ($verified, $note) = $self->_verify_task_effect($api, $task);
        $verify_note = $note;
        if (!$verified) {
            if (($task->{action} // '') eq 'redeem'
                && defined($self->{cfg}{loser_sweep_to})
                && $self->{cfg}{loser_sweep_to} =~ /^0x[0-9a-fA-F]{40}$/
                && defined($task->{token_dec})) {
                my $sweep_res = $api->close_zero_value_position(
                    token_dec    => $task->{token_dec},
                    amount       => $task->{amount},
                    condition_id => $task->{condition_id},
                    sweep_to     => $self->{cfg}{loser_sweep_to},
                    prefer_sweep => 1,
                );

                my $sweep_ok = $sweep_res->{ok} ? 1 : 0;
                if ($sweep_ok) {
                    my ($sweep_verified, $sweep_note) = $self->_verify_task_effect($api, $task);
                    $verify_note = "redeem_verify_failed_then_sweep: " . ($sweep_note // '');
                    if ($sweep_verified) {
                        $ok = 1;
                        $error = undef;
                        $res = {
                            ok       => JSON::PP::true,
                            response => $sweep_res->{response},
                            attempts => [
                                { action => 'redeem', %$res },
                                { action => 'transfer', %$sweep_res },
                            ],
                        };
                    }
                    else {
                        $ok = 0;
                        $error = $sweep_note;
                        $res = {
                            ok       => JSON::PP::false,
                            attempts => [
                                { action => 'redeem', %$res },
                                { action => 'transfer', %$sweep_res },
                            ],
                        };
                    }
                }
                else {
                    $ok = 0;
                    $error = ($note // 'post-action verify failed') . '; sweep retry failed: ' . $self->_summarize_task_error($sweep_res);
                    $res = {
                        ok       => JSON::PP::false,
                        attempts => [
                            { action => 'redeem', %$res },
                            { action => 'transfer', %$sweep_res },
                        ],
                    };
                }
            }
            elsif (($task->{action} // '') eq 'close_loser'
                && defined($self->{cfg}{loser_sweep_to})
                && $self->{cfg}{loser_sweep_to} =~ /^0x[0-9a-fA-F]{40}$/
                && defined($task->{token_dec})
                && defined($task->{amount})) {
                my $sweep_res = $api->close_zero_value_position(
                    token_dec    => $task->{token_dec},
                    amount       => $task->{amount},
                    condition_id => $task->{condition_id},
                    sweep_to     => $self->{cfg}{loser_sweep_to},
                    prefer_sweep => 1,
                );

                my $sweep_ok = $sweep_res->{ok} ? 1 : 0;
                if ($sweep_ok) {
                    my ($sweep_verified, $sweep_note) = $self->_verify_task_effect($api, $task);
                    $verify_note = "redeem_verify_failed_then_sweep: " . ($sweep_note // '');
                    if ($sweep_verified) {
                        $ok = 1;
                        $error = undef;
                    }
                    else {
                        $ok = 0;
                        $error = $sweep_note;
                    }
                }
                else {
                    $ok = 0;
                    $error = ($note // 'post-action verify failed') . '; sweep retry failed: ' . $self->_summarize_task_error($sweep_res);
                }
            }
            else {
                $ok = 0;
                $error = $note;
            }
        }
    }

    return {
        ok          => $ok,
        error       => $error,
        verify_note => $verify_note,
        res         => $res,
    };
}

sub dispatch_workers {
    my ($self) = @_;

    my $limit = $self->{cfg}{worker_count};
    $limit = 1 if $limit < 1;

    while (@{ $self->{pending_tasks} } && scalar(keys %{ $self->{active_workers} }) < $limit) {
        my $pick = 0;
        if ($self->_has_active_redeem_worker()) {
            my $found_non_redeem;
            for my $i (0 .. $#{ $self->{pending_tasks} }) {
                my $cand = $self->{pending_tasks}[$i] || {};
                next if (($cand->{action} // '') eq 'redeem');
                $pick = $i;
                $found_non_redeem = 1;
                last;
            }
            last unless $found_non_redeem;
        }

        my $task = splice(@{ $self->{pending_tasks} }, $pick, 1);
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

    my $is_sell_action = ($action eq 'tp1'
        || $action eq 'tp2'
        || $action eq 'stop_hit'
        || $action eq 'max_loss');

    return 1 if $action eq 'close_loser' && $r =~ /unable to close zero value position/;
    return 1 if $r =~ /no wallet configured/;
    return 1 if $r =~ /post-action verify timeout/;
    return 1 if $action eq 'redeem' && $r =~ /redeem positions failed/;
    return 1 if $is_sell_action
        && $r =~ /not enough balance\s*\/\s*allowance/
        && $r =~ /approve set/;
    return 1 if $is_sell_action && $r =~ /no orderbook exists for the requested token id/;

    return 0;
}

sub _redeem_in_cooldown {
    my ($self, $s) = @_;
    return 0 unless ref($s) eq 'HASH';

    my $cooldown = 0 + ($self->{cfg}{redeem_retry_cooldown_s} // 0);
    return 0 if $cooldown <= 0;

    my $failed = $s->{failed} || {};
    my $at = $failed->{redeem_at};
    return 0 unless defined $at && $at =~ /^\d+$/;

    return (time() - $at) < $cooldown ? 1 : 0;
}

sub _retry_or_clear {
    my ($self, $task, $reason) = @_;
    my $key = $task->{position_key};
    my $action = $task->{action};

    my $is_permanent = $self->_is_permanent_task_failure($action, $reason);
    my $retry = ($task->{retries} // 0) + 1;

    my $task_json = _json_compact($task);
    my $state_json = '{}';
    my $position_json = '{}';
    if (defined $key && exists $self->{state}{positions}{$key}) {
        my $st = $self->{state}{positions}{$key};
        $state_json = _json_compact($st);
        $position_json = _json_compact($st->{last_position});
    }

    my %diag_actions = map { $_ => 1 } qw(redeem close_loser tp1 tp2 stop_hit max_loss);
    if ($diag_actions{$action} && ($reason // '') ne '') {
        my $mode = (!$is_permanent && $retry <= $self->{cfg}{worker_max_retries}) ? 'retrying' : 'giving_up';
        $self->log_line("WARN: task diagnostic action=$action key=$key mode=$mode reason=$reason task=$task_json position=$position_json state=$state_json");
    }

    if (!$is_permanent && $retry <= $self->{cfg}{worker_max_retries}) {
        my %new = %$task;
        $new{retries} = $retry;
        $self->enqueue_task(%new);
        $self->log_line("WARN: retry task action=$action key=$key retry=$retry reason=$reason task=$task_json");
        return;
    }

    if (defined $key && exists $self->{state}{positions}{$key}) {
        delete $self->{state}{positions}{$key}{queued}{$action};

        my $mark_done = 0;
        $mark_done = 1 if $action eq 'close_loser';
        $mark_done = 1 if $is_permanent && $action ne 'tp1' && $action ne 'tp2' && $action ne 'stop_hit' && $action ne 'max_loss' && $action ne 'redeem';

        if ($mark_done) {
            $self->{state}{positions}{$key}{done} ||= {};
            $self->{state}{positions}{$key}{done}{$action} = JSON::PP::true;
        }

        if ($action eq 'redeem') {
            $self->{state}{positions}{$key}{failed} ||= {};
            $self->{state}{positions}{$key}{failed}{redeem_at} = time();
            $self->{state}{positions}{$key}{failed}{redeem_reason} = "$reason";
        }
    }

    my $tag = $is_permanent ? 'permanent failure' : 'retry limit reached';
    $self->log_line("ERR: giving up task action=$action key=$key reason=$reason detail=$tag");
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
                    $self->log_line("INFO: task done action=$task->{action} key=$task->{position_key}" . (defined $decoded->{verify_note} ? " verify=\"$decoded->{verify_note}\"" : ""));
                }
                else {
                    $self->_retry_or_clear($task, $decoded->{error} // 'worker failed');
                    $self->log_line("WARN: task failed action=$task->{action} key=$task->{position_key} err=" . ($decoded->{error} // 'worker failed') . (defined $decoded->{verify_note} ? " verify=\"$decoded->{verify_note}\"" : ""));
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

sub _worker_timeout_for_task {
    my ($self, $task) = @_;

    my $base = $self->{cfg}{worker_timeout_s};
    $base = 0 + ($base // 0);

    my $action = ref($task) eq 'HASH' ? ($task->{action} // '') : '';
    if ($action eq 'close_loser' || $action eq 'redeem' || $action eq 'tp1' || $action eq 'tp2' || $action eq 'stop_hit' || $action eq 'max_loss') {
        return $base unless exists $self->{cfg}{post_action_verify_timeout_s};

        my $verify = $self->{cfg}{post_action_verify_timeout_s};
        $verify = 0 + ($verify // 0);
        my $min_needed = $verify + 15;
        return $min_needed if $base < $min_needed;
    }

    return $base;
}

sub monitor_stalled_workers {
    my ($self, $snapshot) = @_;

    for my $pid (keys %{ $self->{active_workers} }) {
        my $meta = $self->{active_workers}{$pid};
        my $task = $meta->{task};
        my $timeout = $self->_worker_timeout_for_task($task);
        next if $timeout <= 0;

        my $age = time() - ($meta->{started_at} // time());
        next if $age < $timeout;

        my $baseline = $meta->{baseline} || {};
        my $has_progress = $self->_task_has_progress($task, $baseline, $snapshot);
        if ($has_progress) {
            $meta->{started_at} = time();
            $meta->{baseline}   = $snapshot;
            $self->log_line("INFO: worker pid=$pid still progressing action=$task->{action} key=$task->{position_key}");
            next;
        }

        $self->log_line("WARN: worker pid=$pid stalled action=$task->{action} key=$task->{position_key} age=${age}s timeout=${timeout}s, killing");
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

    return if $self->_task_is_busy($s, 'close_loser') || ($s->{done}{close_loser} ? 1 : 0);

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
        $positions = $self->_fetch_manageable_positions($wallet);
    }

    my $snapshot = $self->_position_snapshot($positions);
    $self->{last_snapshot} = $snapshot;
    $self->monitor_stalled_workers($snapshot);

    return unless defined $wallet && $wallet ne '';

    my %seen;

    for my $p (@$positions) {
        next unless ref($p) eq 'HASH';

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
        $s->{last_position} = { %$p };

        if (($s->{done}{redeem} ? 1 : 0) && ($p->{redeemable} ? 1 : 0)) {
            delete $s->{done}{redeem};
            $self->log_line("WARN: clearing stale done.redeem key=$key because position is still redeemable");
        }

        my $redeem_index_set = _index_set_from_outcome_index($p->{outcome_index});
        my $size = _num_or_undef($p->{size});
        my $current_value = _num_or_undef($p->{current_value});
        my $token_dec = $self->_resolve_token_dec($p);
        my $has_token_dec = _is_token_id($token_dec);

        my $is_hidden = $p->{_hidden} ? 1 : 0;
        if ($is_hidden) {
            if ($self->{cfg}{close_on_redeemable}
                && defined($p->{condition_id})
                && $p->{condition_id} ne ''
                && !$self->_task_is_busy($s, 'redeem')
                && !($s->{done}{redeem} ? 1 : 0)
                && !$self->_redeem_in_cooldown($s)
                && !$self->_condition_redeem_busy_or_done($p->{condition_id}, $redeem_index_set)) {
                my $task = $self->_build_task(
                    action       => 'redeem',
                    position_key => $key,
                    token_dec    => ($has_token_dec ? $token_dec : undef),
                    amount       => $size,
                    condition_id => $p->{condition_id},
                    index_set    => $redeem_index_set,
                );
                $self->enqueue_task(%$task);
                $s->{queued}{redeem} = JSON::PP::true;
            }
            next;
        }

        next unless defined $size && $size > 0;

        if ($self->{cfg}{close_on_redeemable}
            && ($p->{redeemable} ? 1 : 0)
            && !$self->_looks_like_loser($p)
            && !$self->_task_is_busy($s, 'redeem')
            && !($s->{done}{redeem} ? 1 : 0)
            && !$self->_redeem_in_cooldown($s)
            && !$self->_condition_redeem_busy_or_done($p->{condition_id}, $redeem_index_set)) {
            my $task = $self->_build_task(
                action       => 'redeem',
                position_key => $key,
                token_dec    => ($has_token_dec ? $token_dec : undef),
                amount       => $size,
                condition_id => $p->{condition_id},
                index_set    => $redeem_index_set,
            );
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
