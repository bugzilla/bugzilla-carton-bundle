package Dockerfile;
use strict;
use warnings;
use base qw(Exporter);
use Carp;
use Cwd 'realpath';
use File::Spec;
use File::Copy 'copy';
use File::Basename;
use File::Path qw(make_path);
use FindBin;
use v5.10.1;

BEGIN { chdir $FindBin::Bin };

our $THIS_DIR = realpath($FindBin::Bin);
our $COPY_DIR = File::Spec->catfile($THIS_DIR, "copy");
our $BASE_DIR = realpath("$FindBin::Bin/..");
our $WORK_DIR = '/opt/bugzilla';
our $GIT_REPO = 'git://github.com/mozilla-bteam/bmo.git';
our $GIT_BRANCH = 'carton';
our $GEN_CPANFILE_ARGS = '-D bmo';
our $NAME = basename($FindBin::Bin);

our @EXPORT = qw(
    FROM RUN CMD COPY ADD MAINTAINER 
    DOCKER_ENV build_bundle $BASE_DIR
    WORKDIR

    copy_from_base
    run_script comment

    $WORK_DIR $GIT_REPO $GIT_BRANCH
    $GEN_CPANFILE_ARGS
);

my %env;
sub _CMD (@) {
    my ($keyword, @args) = @_;
    if (@args == 1 && ref $args[0] && ref $args[0] eq 'ARRAY') {
        say $keyword, ' [', join(', ', map { docker_quote($_) } @{$args[0]}), ']';
    } else {
        say join(' ', $keyword, map { docker_arg($_, $keyword) } @args)
    }
}

sub DOCKER_ENV ($$) {
    my ($k, $v) = @_;
    $env{$k} = '$'.$k;;
    _CMD('ENV', $k, $v);
}

sub FROM ($)       { _CMD 'FROM', @_ }
sub ADD ($;$)       { _CMD 'ADD', @_ }
sub COPY ($;$)      { _CMD 'COPY', @_ }
sub MAINTAINER ($) { _CMD 'MAINTAINER', @_ }
sub WORKDIR ($)    { _CMD 'WORKDIR', @_ }
sub RUN ($)        { _CMD 'RUN', @_ }
sub CMD ($)        { _CMD 'CMD', @_ }

sub comment ($) {
    my ($comment) = @_;
    $comment =~ s/^\s*/# /gm;
    $comment =~ s/\n+$//s;
    say $comment;
}

sub build_perl_and_carton {
    my (%param) = @_;
    comment "build perl and carton";
    DOCKER_ENV PERL_DIR => '/opt/vanilla-perl';
    DOCKER_ENV PERL     => '$PERL_DIR/bin/perl';
    DOCKER_ENV SYSTEM_PERL => $param{system_perl};
    DOCKER_ENV CARTON   => '$PERL_DIR/bin/carton';

    ADD 'https://raw.github.com/tokuhirom/Perl-Build/master/perl-build', '/usr/local/bin/perl-build';
    ADD 'https://raw.githubusercontent.com/miyagawa/cpanminus/master/cpanm', '/usr/local/bin/cpanm';
    RUN 'chmod a+x /usr/local/bin/perl-build /usr/local/bin/cpanm';
    run_script('build-vanilla-perl');
    RUN q{
        $PERL /usr/local/bin/cpanm --notest --quiet
            Carton App::FatPacker File::pushd ExtUtils::MakeMaker
    };
}

sub build_bundle {
    my (%param) = @_;
    $param{system_perl} //= '/usr/bin/perl';
    build_perl_and_carton(%param);

    comment "git clone";
    DOCKER_ENV BUGZILLA_DIR => $WORK_DIR;
    DOCKER_ENV GIT_BRANCH   => $GIT_BRANCH;
    DOCKER_ENV GEN_CPANFILE_ARGS => $GEN_CPANFILE_ARGS;
    RUN ["git", "clone", "-b", $GIT_BRANCH, $GIT_REPO, $WORK_DIR];
    WORKDIR $WORK_DIR;

    if (-f 'cpanfile.snapshot') {
        comment "add cpanfile.snapshot";
        COPY 'cpanfile.snapshot', 'cpanfile.snapshot';
        COPY 'cpanfile.snapshot', 'cpanfile.original_snapshot';
    }
    else {
        warn "$NAME/Dockerfile.PL: no cpanfile.snapshot!\n";
    }

    my @scripts = (
        'probe-libs',
        'scan-libs',
        'probe-packages',
        'build-bundle',
        'update-modules',
        'package-bundle',
        'fetch-pari',
    );
    copy_from_base("scripts/$_", "/usr/local/bin/$_") for @scripts;
    RUN ["chmod", "a+x", map { "/usr/local/bin/$_" } @scripts];

    DOCKER_ENV NAME     => $NAME;
    DOCKER_ENV S3_BUCKET_URI => $ENV{S3_BUCKET_URI} if $ENV{S3_BUCKET_URI};
    DOCKER_ENV PERL5LIB => "$WORK_DIR/local/lib/perl5";
    CMD 'build-bundle';
}

sub copy_from_base {
    my ($src, $dest) = @_;
    comment "copy \$BASE_DIR/$src to $dest";

    my $src_path = File::Spec->catfile($BASE_DIR, $src);
    my $tmp_path = File::Spec->catfile($COPY_DIR, $src);

    make_path(dirname($tmp_path));
    copy($src_path, $tmp_path)
        or die "copy failed: $! $src_path -> $tmp_path";
    COPY [File::Spec->abs2rel($tmp_path), $dest];
}

sub run_script {
    my ($name) = @_;
    my $script = "/usr/local/bin/$name";
    copy_from_base("scripts/$name", $script);
    RUN ["chmod", "755", $script];
    RUN [$script];
}

sub docker_arg {
    my ($item, $keyword) = @_;
    my $prefix = ' ' x (length($keyword) + 1);
    $item =~ s/^\s+//gs;
    $item =~ s/\s+$//gs;
    $item =~ s/\n[ \t]*/ \\\n$prefix/gs;
    while ($item =~ /[^\\]\$(\w+)/g) {
        croak "Undefined variable: \$$1" unless $env{$1};
    }
    return $item;
}

sub docker_quote {
    my ($item) = @_;
    $item =~ s/(["\\])/\\$1/gs;
    $item =~ s/\n/\\n/gs;
    return qq{"$item"};
}
1;
