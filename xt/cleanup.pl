#!/usr/bin/env perl
use utf8;
use warnings;
use FindBin '$Bin';
use lib "$Bin/..";
use xt::Util;
chdir $Bin;

my $ssh_config = "$ENV{HOME}/.ssh/config";
my @content = -f $ssh_config ? slurp($ssh_config) : ();
my @new_content;
my $remove;
for my $line (@content) {
    if ( $line =~ /^Host example00[1-3]/ ) {
        $remove = 1;
    } elsif ( $line =~ /^\S/ && $line !~ /^Host example00[1-3]/ ) {
        $remove = 0;
    }
    push @new_content, $line unless $remove;
}

for my $host (map { sprintf "example00%d", $_ } 1..3) {
    my $g = pushd $host;
    run "vagrant destroy -f";
}

open my $fh, ">", $ssh_config or die $!;
print {$fh} @new_content;
