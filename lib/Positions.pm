package Positions;
use strict;
use warnings;

use JSON::PP ();
use Capture::Tiny qw(capture);

sub new {
    my ($class, %args) = @_;
    my $self = {
        signature_type => ($args{signature_type} // ''),
        page_size      => ($args{page_size} // 200),
    };
    return bless $self, $class;
}

sub json_decode {
    my ($self, $txt) = @_;
    my $j = JSON::PP->new->utf8->allow_nonref;
    return $j->decode($txt);
}

sub run_cmd_capture {
    my ($self, @cmd) = @_;
    my ($stdout, $stderr, $exit) = capture { system @cmd };

    if ($exit != 0 && !$stderr && $stdout) {
        $stderr = $stdout;
        $stdout = '';
    }

    return ($exit, $stdout, $stderr);
}

sub polymarket_cmd_capture {
    my ($self, $needs_wallet, @args) = @_;
    my @cmd = ('polymarket');
    if ($needs_wallet && defined $self->{signature_type} && $self->{signature_type} ne '') {
        push @cmd, ('--signature-type', $self->{signature_type});
    }
    push @cmd, @args;
    return $self->run_cmd_capture(@cmd);
}

sub wallet_address {
    my ($self) = @_;
    my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(0, 'wallet', 'address');
    die "Failed polymarket wallet address\n$stderr\n" if $exit != 0;

    $stdout =~ s/^\s+|\s+$//g;
    die "Could not parse wallet address\n" unless $stdout =~ /^0x[0-9a-fA-F]{40}$/;
    return $stdout;
}

sub fetch_positions {
    my ($self, $wallet) = @_;
    my @all;
    my $offset = 0;

    while (1) {
        my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(
            0,
            '-o', 'json', 'data', 'positions', $wallet,
            '--limit', $self->{page_size}, '--offset', $offset,
        );
        die "Failed: polymarket data positions\n$stderr\n" if $exit != 0;

        my $arr = $self->json_decode($stdout);
        die "Expected array from data positions\n" unless ref($arr) eq 'ARRAY';

        last if !@$arr;
        push @all, @$arr;
        last if @$arr < $self->{page_size};
        $offset += $self->{page_size};
    }

    return \@all;
}

sub market_sell {
    my ($self, %args) = @_;
    my $token_dec = $args{token_dec};
    my $amount    = $args{amount};

    my @cmd = (
        '-o', 'json', 'clob', 'market-order',
        '--token', $token_dec, '--side', 'sell', '--amount', $amount,
    );

    my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(1, @cmd);
    return {
        ok    => JSON::PP::false,
        error => $stderr || 'sell failed',
    } if $exit != 0;

    my $resp = eval { $self->json_decode($stdout) };
    $resp = { raw => $stdout } if $@;
    return { ok => JSON::PP::true, response => $resp };
}

sub redeem_condition {
    my ($self, %args) = @_;
    my $condition_id = $args{condition_id};

    my ($exit, $stdout, $stderr) = $self->polymarket_cmd_capture(
        1,
        '-o', 'json', 'ctf', 'redeem', '--condition', $condition_id,
    );

    return {
        ok    => JSON::PP::false,
        error => $stderr || 'redeem failed',
    } if $exit != 0;

    my $resp = eval { $self->json_decode($stdout) };
    $resp = { raw => $stdout } if $@;
    return { ok => JSON::PP::true, response => $resp };
}

1;
