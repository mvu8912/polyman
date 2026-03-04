package Capture::Tiny;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(capture);

sub capture (&) {
    my ($code) = @_;
    my ($stdout, $stderr);
    my $ok = eval {
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$stdout;
        open STDERR, '>', \$stderr;
        $code->();
        1;
    };
    die $@ unless $ok;
    return ($stdout // '', $stderr // '', 0);
}

1;
