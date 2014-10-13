requires 'perl', '5.008005';
requires 'IO::Prompt';
requires 'Net::OpenSSH';
requires 'Parallel::ForkManager';
requires 'IO::Pty';

on test => sub {
    requires 'Test::More', '0.98';
};
