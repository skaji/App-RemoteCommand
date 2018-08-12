package Util;
use strict;
use warnings;
use File::pushd 'pushd';
use Capture::Tiny qw(capture);
use File::Temp ();

use Exporter 'import';
our @EXPORT = qw(pushd slurp spew run rcommand tempfile guard);
sub run { !system @_ or die "FAIL @_" }
sub slurp { my $file = shift; open my $fh, "<", $file or die $!; <$fh> }
sub spew { my ($file, $str) = @_; open my $fh, ">", $file or die $!; print {$fh} $str }

{
    package Result;
    sub new { bless $_[1], $_[0] }
    no strict 'refs';
    for my $attr (qw(stdout stderr exit)) {
        *$attr = sub { shift->{$attr} };
    }
}
sub rcommand {
    my @command = @_;
    my $script = "script/rcommand";
    my ($stdout, $stderr, $exit) = capture {
        system $^X, "-Ilib", "--", $script, "-F", "xt/ssh_config", @command;
    };
    Result->new({ stdout => $stdout, stderr => $stderr, exit => $exit });
}

sub tempfile {
    my $content = shift || "";
    my ($fh, $name) = File::Temp::tempfile UNLINK => 1;
    print {$fh} $content;
    close $fh;
    $name;
}

{
    package Guard;
    sub new {
        my ($class, $sub) = @_;
        bless { owner => $$, sub => $sub }, $class;
    }
    sub DESTROY {
        my $self = shift;
        return if $self->{owner} != $$;
        $self->{sub}->();
    }
}

sub guard (&) {
    my $sub = shift;
    Guard->new($sub);
}

1;
