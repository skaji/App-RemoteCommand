package App::RemoteCommand;
use strict;
use warnings;
use utf8;
use Errno ();
use File::Basename qw(basename);
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case bundling);
use IO::Handle;
use IO::Prompt 'prompt';
use IO::Pty;
use IO::Select;
use List::MoreUtils qw(uniq);
use Net::OpenSSH;
use POSIX qw(strftime);
use Parallel::ForkManager;
use Pod::Usage 'pod2usage';
use String::Glob::Permute qw(string_glob_permute);

use constant CHUNK_SIZE => 64 * 1024;

my $SUDO_PROMPT = sprintf "sudo password (asking with %s): ", basename($0);

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

    my $signal_recieved;
    $SIG{INT} = $SIG{TERM} = sub {
        $signal_recieved++;
        my $signal = shift;
        my @pid = keys %{$pm->{processes}};
        kill $signal, @pid;
    };

    for my $host (@{ $self->{host} }) {
        last if $signal_recieved;
        $pm->start($host) and next;
        $SIG{INT}  = "DEFAULT";
        $SIG{TERM} = "DEFAULT";
        my $exit = eval { $self->do_ssh($host) };
        if (my $e = $@) {
            chomp $e;
            warn "$e\n";
            $exit = 255;
        }
        $pm->finish($exit);
    }

    while (%{$pm->{processes}}) {
        $pm->wait_all_children;
    }

    my @success = grep { $exit{$_}{exit} == 0 && !$exit{$_}{signal} } sort keys %exit;
    my @fail    = grep { $exit{$_}{exit} != 0 ||  $exit{$_}{signal} } sort keys %exit;
    print STDERR "\e[32mSUCCESS\e[m $_\n" for @success;
    print STDERR "\e[31mFAIL\e[m $_\n"   for @fail;
    return @fail ? 1 : 0;
}

sub make_command {
    my ($self, @command) = @_;
    my @prefix = ("env", "SUDO_PROMPT=$SUDO_PROMPT");
    if (@command == 1) {
        (@prefix, "bash", "-c", $command[0]);
    } else {
        (@prefix, @command);
    }
}

sub piping {
    my ($self, $host, $in_fh, $out_fh, $keep) = @_;
    my $len = sysread $in_fh, my $buffer, CHUNK_SIZE;
    if (!defined $len) {
        if ($! == Errno::EIO) {
            # this happens when use ssh proxy, so skip
        } else {
            print STDERR $self->format->($host, "Internal error, sysread: $!");
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
        user => $self->{user},
        ( $self->{identity} ? (key_path => $self->{identity}) : () ),
        strict_mode => 0,
        timeout => 5,
        kill_ssh_on_timeout => 1,
        master_opts => [
            -o => "StrictHostKeyChecking=no",
            -o => "UserKnownHostsFile=/dev/null",
            -o => "LogLevel=quiet",
        ],
    );

    my $internal_error = sub {
        my $error = shift || $ssh->error || "";
        $self->format->($host, "Internal error, $error");
    };

    die $internal_error->() if $ssh->error;

    my $do_clean = sub {};
    if (my $script = $self->{script}) {
        my $name = sprintf "/tmp/%s.%d.%d.%d", basename($0), time, $$, rand(1000);
        $ssh->scp_put( $script, $name ) or die $internal_error->();
        $do_clean = sub { $ssh->system("rm", "-f", $name) }; # don't check error
        $ssh->system("chmod", "700", $name) or do { $do_clean->(); die $internal_error->() };
        @command = ($name);
    }
    my ($pty, $pid) = $ssh->open2pty($self->make_command(@command))
        or do { $do_clean->(); die $internal_error->() };

    $SIG{$_} = sub {
        my $signal = shift;
        close $pty;
        waitpid $pid, 0;
        # TODO if the child master ssh process have already recieved signal
        # (this happens when you hit Ctrl+C and send SIGINT to all process group),
        # then ssh connection would be broken, and $do_clean doesn't work...
        $do_clean->();
        die $internal_error->("catch signal $signal, thus die");
    } for qw(INT TERM);

    my $select = IO::Select->new($pty);
    my $keep = "";
    my $need_password;
    my $error;
    while (1) {
        last unless kill 0 => $pid;
        if ($select->can_read(1)) {
            my $len = $self->piping($host, $pty => \*STDOUT, \$keep);
            if ($len == 0) {
                print STDOUT $self->format->($host, $keep) if $keep;
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
                $error = "have to provide sudo passowrd first, try again with --ask-sudo-password option.";
                last;
            }
        }
    }
    close $pty or die $internal_error->("close pty: $!");
    waitpid $pid, 0;
    my $exit = $?;
    $do_clean->();
    if ($error) {
        die $internal_error->($error);
    } else {
        return $exit >> 8;
    }
}

sub parse_host_arg {
    my ($self, $host_arg) = @_;
    [ uniq string_glob_permute($host_arg) ];
}

sub parse_host_file {
    my ($self, $host_file) = @_;
    open my $fh, "<", $host_file or die "Cannot open '$host_file': $!\n";
    my @host;
    while (my $line = <$fh>) {
        $line =~ s/^\s+//; $line =~ s/\s+$//;
        push @host, $line if $line =~ /^[^#\s]/;
    }
    [ uniq @host ];
}

sub parse_options {
    my ($self, @argv) = @_;
    local @ARGV = @argv;
    GetOptions
        "c|concurrency=i"     => \($self->{concurrency} = 5),
        "h|help"              => sub { pod2usage(0) },
        "u|user=s"            => \($self->{user} = $ENV{USER}),
        "i|identity=s"        => \($self->{identity}),
        "s|script=s"          => \($self->{script}),
        "v|version"           => sub { printf "%s %s\n", __PACKAGE__, $VERSION; exit },
        "a|ask-sudo-password" => \(my $ask_sudo_password),
        "H|host-file=s"       => \(my $host_file),
        "sudo-password=s"     => \($self->{sudo_password}),
        "append-hostname!"    => \(my $append_hostname = 1),
        "append-time!"        => \(my $append_time),
    or pod2usage(1);

    my $host_arg = $host_file ? undef : shift @ARGV;
    my @command = @ARGV;

    if (!@command && !$self->{script}) {
        warn "COMMANDS or --script option is required\n";
        pod2usage(1);
    }
    if ($self->{script} && !-r $self->{script}) {
        die "Cannot read script '$self->{script}'\n";
    }

    $self->{format} = $self->make_format(
        append_hostname => $append_hostname,
        append_time => $append_time,
    );

    if ($ask_sudo_password) {
        my $password = prompt $SUDO_PROMPT, -echo => undef;
        $self->{sudo_password} = $password;
    }
    $self->{host} = $host_file ? $self->parse_host_file($host_file)
                               : $self->parse_host_arg($host_arg);
    $self->{command} = \@command;
    $self;

}

1;
__END__

=encoding utf-8

=for stopwords passphrase

=head1 NAME

App::RemoteCommand - simple remote command launcher via ssh

=head1 SYNOPSIS

    > rcommand [OPTIONS] HOSTS COMMANDS
    > rcommand [OPTIONS] --script SCRIPT HOSTS
    > rcommand [OPTIONS] --host-file FILE COMMANDS

=head1 DESCRIPTION

App::RemoteCommand is a simple remote command launcher via ssh. The features are:

=over 4

=item * execute remote command in parallel

=item * remember sudo password first, and never ask again

=item * you may specify a script file in local machine

=item * append hostname and time to each command output lines

=item * report success/fail summary

=back

=head1 CAVEATS

Currently this module assumes you can ssh the target hosts
without password or passphrase.
So if your ssh identity (ssh private key) requires a passphrase,
please use C<ssh-agent>.

=head1 LICENSE

Copyright (C) Shoichi Kaji.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=head1 AUTHOR

Shoichi Kaji E<lt>skaji@cpan.orgE<gt>

=cut
