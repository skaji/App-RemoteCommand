use strict;
use warnings;
use utf8;
use Test::More;
use xt::Util;

unless ( -d ".git" && system("ssh example001 w &>/dev/null") == 0 ) {
    plan skip_all => "Please setup virtual machines first";
}

subtest one => sub {
    subtest test => sub {
        my $r = rcommand("example999", "ls");
        ok $r->exit != 0;
        like $r->stderr, qr/Internal error/;
        like $r->stderr, qr/FAIL/;
    };
    subtest test => sub {
        my $r = rcommand("example001", "false");
        ok $r->exit != 0;
        like $r->stderr, qr/FAIL/;
    };
    subtest test => sub {
        my $r = rcommand("example001", "uname");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS/;
        is $r->stdout, "[example001] Linux\n";
    };

    my $time = qr/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/;
    subtest test => sub {
        my $r = rcommand("--no-append-hostname", "example001", "uname");
        is $r->stdout, "Linux\n";
    };
    subtest test => sub {
        my $r = rcommand("--no-append-hostname", "--append-time", "example001", "uname");
        like $r->stdout, qr/^\[$time\] Linux\n$/;
    };
    subtest test => sub {
        my $r = rcommand("--append-time", "example001", "uname");
        like $r->stdout, qr/\[$time\]\[example001\] Linux\n$/;
    };

    subtest test => sub {
        my $r = rcommand("--sudo-password", "skaji", "example001", "sudo uname");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS/;
        like $r->stdout, qr/\[example001\] Linux/;
    };

    subtest test => sub {
        my $script = tempfile("#!/bin/bash\nuname\n");
        my $r = rcommand("--script", $script, "example001");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS/;
        is $r->stdout, "[example001] Linux\n";
    };

    subtest test => sub {
        my $script = tempfile("#!/bin/bash\nsudo uname\n");
        my $r = rcommand("--script", $script, "--sudo-password", "skaji", "example001");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS/;
        like $r->stdout, qr/\[example001\] Linux\n/;
    };

    subtest test => sub {
        my $host_file = tempfile("\n\n  \n# comment\nexample001");
        my $r = rcommand("--host-file", $host_file, "uname");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS/;
        is $r->stdout, "[example001] Linux\n";
    };
};

subtest three => sub {
    subtest test => sub {
        my $r = rcommand("example00[1-3]", "false");
        ok $r->exit != 0;
        like $r->stderr, qr/FAIL.*FAIL.*FAIL/sm;
    };

    subtest test => sub {
        my $r = rcommand("example00[1-3]", "uname");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS.*SUCCESS.*SUCCESS/sm;
        like $r->stdout, qr/\[example00$_\] Linux\n/ for 1..3;
    };

    subtest test => sub {
        rcommand("example003", "echo foo > foo");
        my $r = rcommand("example00[1-3]", "ls foo");
        ok $r->exit != 0;
        my $end = "\e[m"; $end = qr/\Q$end\E/;
        like $r->stderr, qr/FAIL$end example001/;
        like $r->stderr, qr/FAIL$end example002/;
        like $r->stderr, qr/SUCCESS$end example003/;
    };

    subtest test => sub {
        my $r = rcommand("--sudo-password", "skaji", "example[001-003]", "sudo uname");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS.*SUCCESS.*SUCCESS/sm;
        like $r->stdout, qr/\[example00$_\] Linux\n/ for 1..3;
    };

    subtest test => sub {
        my $script = tempfile("#!/bin/bash\nuname\n");
        my $r = rcommand("--script", $script, "example001,example002,example003");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS.*SUCCESS.*SUCCESS/sm;
        like $r->stdout, qr/\[example00$_\] Linux\n/ for 1..3;
    };

    subtest test => sub {
        my $script = tempfile("#!/bin/bash\nsudo uname\n");
        my $r = rcommand("--script", $script, "--sudo-password", "skaji", "example00[1-3]");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS.*SUCCESS.*SUCCESS/sm;
        like $r->stdout, qr/\[example00$_\] Linux\n/ for 1..3;
    };

    subtest test => sub {
        my $host_file = tempfile("example001\nexample002\nexample003\n\n");
        my $r = rcommand("-H", $host_file, "uname");
        is $r->exit, 0;
        like $r->stderr, qr/SUCCESS.*SUCCESS.*SUCCESS/sm;
        like $r->stdout, qr/\[example00$_\] Linux\n/ for 1..3;
    };
};

done_testing;
