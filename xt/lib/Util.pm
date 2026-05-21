package Util;
use v5.24;
use warnings;
use experimental qw(lexical_subs signatures);

use File::pushd 'pushd';
use Capture::Tiny qw(capture);
use File::Temp ();

use Exporter 'import';
our @EXPORT = qw(pushd slurp spew run rcommand tempfile guard);
sub run (@args) { !system @args or die "FAIL @args" }
sub slurp ($file) { open my $fh, "<", $file or die $!; <$fh> }
sub spew ($file, $str) { open my $fh, ">", $file or die $!; print {$fh} $str }

package Result {
    sub new ($class, $value) { bless $value, $class }
    no strict 'refs';
    for my $attr (qw(stdout stderr exit)) {
        *$attr = sub ($self) { $self->{$attr} };
    }
}

sub rcommand (@command) {
    my $script = "script/rcommand";
    my ($stdout, $stderr, $exit) = capture {
        system $^X, "-Ilib", "--", $script, "-F", "xt/ssh_config", @command;
    };
    Result->new({ stdout => $stdout, stderr => $stderr, exit => $exit });
}

sub tempfile ($content = "") {
    my ($fh, $name) = File::Temp::tempfile UNLINK => 1;
    print {$fh} $content;
    close $fh;
    $name;
}

package Guard {
    sub new ($class, $sub) {
        bless { owner => $$, sub => $sub }, $class;
    }
    sub DESTROY ($self) {
        return if $self->{owner} != $$;
        $self->{sub}->();
    }
}

{
    no feature 'signatures';
    sub guard (&) {
        my $sub = shift;
        Guard->new($sub);
    }
}

1;
