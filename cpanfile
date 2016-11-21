requires 'perl', '5.008005';
requires 'IO::Pty';
requires 'List::MoreUtils';
requires 'Net::OpenSSH';
requires 'Parallel::ForkManager', '1.16'; # 1.15 has CPU 100% bug
requires 'String::Glob::Permute';
requires 'Term::ReadKey';

on test => sub {
    requires 'Test::More', '0.98';
};
