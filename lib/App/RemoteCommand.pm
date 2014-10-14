package App::RemoteCommand;
use strict;
use warnings;
use utf8;
use File::Basename qw(basename);
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case bundling);
use IO::Handle;
use IO::Prompt 'prompt';
use IO::Pty;
use IO::Select;
use Net::OpenSSH;
use POSIX qw(strftime setsid);
use Parallel::ForkManager;
use Pod::Usage 'pod2usage';
use Errno ();

use constant CHUNK_SIZE => 64 * 1024;

my $SUDO_PROMPT = sprintf "sudo password (asking by %s): ", basename($0);

STDOUT->autoflush(1);

our $VERSION = '0.01';

sub new {
    my $class = shift;
    bless {@_}, $class;
}

sub format { shift->{format} }

sub make_format {
    my ($self, %opt) = @_;
    if ($opt{append_time} && $opt{append_hostname}) {
        sub { my ($host, $msg) = @_; "[@{[strftime '%F %T', localtime]}][$host] $msg\n" };
    } elsif ($opt{append_time}) {
        sub { my ($host, $msg) = @_; "[@{[strftime '%F %T', localtime]}] $msg\n" };
    } elsif ($opt{append_hostname}) {
        sub { my ($host, $msg) = @_; "[$host] $msg\n" };
    } else {
        sub { my ($host, $msg) = @_; "$msg\n" };
    }
}

sub run {
    my $self = shift;
    my $pm = Parallel::ForkManager->new($self->{concurrency});
    my %exit; $pm->run_on_finish(sub {
        my ($pid, $exit, $host, $signal) = @_;
        $exit{$host} = { exit => $exit, signal => $signal };
    });

    setsid;
    my $signal_recieved;
    local $SIG{INT} = local $SIG{TERM} = sub {
        my $signal = shift;
        local $SIG{$signal} = "IGNORE";
        kill $signal => -$$;
        $signal_recieved++;
    };

    for my $host (@{ $self->{host} }) {
        last if $signal_recieved;
        if ( (grep {$exit{$_}{exit} || $exit{$_}{signal}} sort keys %exit) > 2) {
            warn "More than 2 hosts failed, thus stop executing.\n";
            last; # XXX
        }
        $pm->start($host) and next;
        $SIG{INT} = $SIG{TERM} = "DEFAULT";
        my $exit = eval { $self->do_ssh($host) };
        if (my $e = $@) {
            chomp $e;
            warn "$e\n";
            $exit = 255;
        }
        $pm->finish($exit);
    }

    while (keys %{$pm->{processes}}) {
        $pm->wait_all_children;
    }

    my @success = grep { $exit{$_}{exit} == 0 && !$exit{$_}{signal} } sort keys %exit;
    my @fail    = grep { $exit{$_}{exit} != 0 || $exit{$_}{signal}  } sort keys %exit;
    print STDERR "\e[32mSUCESS\e[m $_\n" for @success;
    print STDERR "\e[31mFAIL\e[m $_\n" for @fail;
    return @fail ? 1 : 0;
}

sub make_command {
    my ($self, @command) = @_;
    my @prefix = ("env", "SUDO_PROMPT=$SUDO_PROMPT");
    if (@command == 1 && $command[0] =~ /\s/) {
        (@prefix, "bash", "-c", $command[0]);
    } else {
        (@prefix, @command);
    }
}

sub piping {
    my ($self, $host, $in_fh, $out_fh, $keep) = @_;
    my $len = sysread $in_fh, my $buffer, CHUNK_SIZE;
    if (!defined $len) {
        if ($! == Errno::EIO) { # this happens when use ssh proxy, so skip
        } else {
            warn "[$host] sysread error: $!\n";
        }
        return 0;
    }
    if ($len == 0) {
        return 0;
    }
    my @split = split /\r?\n/, $buffer;

    if (@split > 1) {
        print {$out_fh} $self->format->($host, $$keep . $split[0]);
        print {$out_fh} $self->format->($host, $_) for @split[1 .. ($#split -1)];
        $$keep = $split[-1];
    } elsif (@split == 1) {
        $$keep .= $split[0];
    }

    if ($buffer =~ /\n$/) {
        print {$out_fh} $self->format->($host, $$keep);
        $$keep = "";
    }

    if (length $$keep > CHUNK_SIZE) {
        print {$out_fh} $self->format->($host, $$keep);
        $$keep = "";
    }
    return $len;
}

sub do_ssh {
    my ($self, $host) = @_;
    my @command = @{$self->{command}};

    my $ssh = Net::OpenSSH->new($host,
        strict_mode => 0,
        timeout => 5,
        kill_ssh_on_timeout => 1,
        master_opts => [
            -o => "StrictHostKeyChecking=no",
            -o => "UserKnownHostsFile=/dev/null",
            -o => "LogLevel=quiet",
        ],
    );

    die $ssh->error, "\n" if $ssh->error;

    my $do_clean = sub {};
    if (my $script = $self->{script}) {
        my $name = sprintf "/tmp/%s.%d.%d.%d", basename($script), time, $$, rand(1000);
        $ssh->scp_put( $script, $name ) or die $ssh->error;
        $do_clean = sub { $ssh->system("rm", "-f", $name) };
        $ssh->system("chmod", "744", $name) or do { $do_clean->(); die $ssh->error };
        @command = ($name);
    }
    my ($pty, $pid) = $ssh->open2pty($self->make_command(@command))
        or do { $do_clean->(); die $ssh->error, "\n" };

    my $select = IO::Select->new($pty);
    my $keep = "";
    my $need_password;
    my $error;
    while (1) {
        last unless kill 0 => $pid;
        if ($select->can_read(1)) {
            my $len = $self->piping($host, $pty => \*STDOUT, \$keep);
            if ($len == 0) {
                print STDOUT $self->output($host, $keep) if $keep;
                last;
            }
            if ($keep =~ /\Q$SUDO_PROMPT\E$/) {
                $need_password = 1;
                print STDOUT $self->format->($host, $keep);
                $keep = "";
            }
        }
        if ($need_password) {
            if (my $sudo_password = $self->{sudo_password}) {
                syswrite $pty, "$sudo_password\n";
                $need_password = 0;
            } else {
                $error = "have to provide sudo passowrd first";
                last;
            }
        }
    }
    close $pty or die "close pty: $!\n";
    waitpid $pid, 0;
    my $exit = $?;
    $do_clean->();
    if ($error) {
        die "$error\n";
    } else {
        return $exit >> 8;
    }
}

sub parse_host_arg {
    my ($self, $host_arg) = @_;
    [ split /\s*,\s*/, $host_arg ];
}

sub parse_options {
    my ($self, @argv) = @_;
    local @ARGV = @argv;
    GetOptions
        "concurrency|C=i"     => \($self->{concurrency} = 5),
        "help|h"              => sub { pod2usage(0) },
        "sudo-password=s"     => \($self->{sudo_password}),
        "ask-sudo-password|A" => \(my $ask_sudo_password),
        "append-hostname!"    => \(my $append_hostname = 1),
        "append-time!"        => \(my $append_time),
        "user=s"              => \($self->{user} = $ENV{USER}),
        "script|s=s"          => \($self->{script}),
        "version|v"           => sub { printf "%s %s\n", __PACKAGE__, $VERSION; exit },
    or pod2usage(1);

    my ($host_arg, @command) = @ARGV;

    if (!@command && !$self->{script}) {
        warn "COMMAND or --script option is required\n";
        pod2usage(1);
    }
    if ($self->{script} && !-r $self->{script}) {
        die "Cannot read '$self->{script}'\n";
    }

    $self->{format} = $self->make_format(
        append_hostname => $append_hostname,
        append_time => $append_time,
    );

    if ($ask_sudo_password) {
        my $password = prompt $SUDO_PROMPT, -echo => undef;
        $self->{sudo_password} = $password;
    }
    $self->{host} = $self->parse_host_arg($host_arg);
    $self->{command} = \@command;
    $self;

}


1;
__END__

=encoding utf-8

=head1 NAME

App::RemoteCommand - simple remote command launcher

=head1 SYNOPSIS

    > rcommand [OPTIONS] HOST COMMAND...

=head1 INSTALL

    > cpanm git://github.com/shoichikaji/App-RemoteCommand.git

=head1 DESCRIPTION

App::RemoteCommand is a simple remote command launcher. The features are:

=over 4

=item * execute remote command in parallel

=item * remember sudo password first, and never ask again

=item * you may specify a script file in local machine

=item * append hostname and time to each command output lines

=item * report success/fail summary

=back

=head1 LICENSE

Copyright (C) Shoichi Kaji.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=head1 AUTHOR

Shoichi Kaji E<lt>skaji@cpan.orgE<gt>

=cut
