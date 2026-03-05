#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Time::HiRes qw(sleep);
use Manager;

sub main {
    my $manager = Manager->new_from_env();
    my $wallet = $manager->wallet // 'unconfigured';
    $manager->log_line("Manager started for wallet=$wallet poll=" . $manager->poll_interval_s . "s");

    while (1) {
        eval { $manager->run_iteration(); };
        if ($@) {
            my $err = $@;
            $err =~ s/\s+$//;
            $manager->log_line("ERR: loop failed: $err");
        }
        sleep($manager->poll_interval_s);
    }
}

main();
