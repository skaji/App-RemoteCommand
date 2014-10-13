# NAME

App::RemoteCommand - simple remote command launcher

# SYNOPSIS

    > rcommand [OPTIONS] HOST COMMAND...

# INSTALL

    > cpanm git://github.com/shoichikaji/App-RemoteCommand.git

# DESCRIPTION

App::RemoteCommand is a simple remote command launcher. The features are:

- execute remote command in parallel
- remember sudo password first, and never ask again
- you may specify a script file in local machine
- append hostname and time to each command output lines
- report success/fail summary

# LICENSE

Copyright (C) Shoichi Kaji.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

# AUTHOR

Shoichi Kaji <skaji@cpan.org>
