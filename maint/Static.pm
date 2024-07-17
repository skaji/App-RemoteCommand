package Static {
    use v5.40;
    use Moose;
    with 'Dist::Zilla::Role::MetaProvider';
    sub metadata { +{ x_static_install => 1 } }
}
