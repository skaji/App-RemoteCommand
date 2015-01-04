Ho to run tests in `xt` directory

I assume you have vagrant and `ubuntu/trusty64` vagrant box.

1. Setup 3 vagrant virtual machine `example00[1-3]`, and modify your `~/.ssh/config`:

        > perl xt/prepare.pl

2. Run tests

        > prove -lv xt

3. Cleanup

        > perl xt/cleanup.pl
