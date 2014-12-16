requires 'perl', '5.008005';
requires 'IO::Prompt';
requires 'IO::Pty';
requires 'List::MoreUtils';
requires 'Net::OpenSSH';
requires 'Parallel::ForkManager';
requires 'String::Glob::Permute';

on test => sub {
    requires 'Test::More', '0.98';
};
