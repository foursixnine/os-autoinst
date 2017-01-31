# Copyright © 2009-2013 Bernhard M. Wiedemann
# Copyright © 2012-2015 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package bmwqemu;
use strict;
use warnings;
use Time::HiRes qw(sleep gettimeofday);
use IO::Socket;
use Fcntl ':flock';

use Thread::Queue;
use POSIX;
use Term::ANSIColor;
use Carp;
use JSON;
use File::Path 'remove_tree';
use Data::Dumper;

use base 'Exporter';
use Exporter;

our $VERSION;
our @EXPORT    = qw(fileContent save_vars);
our @EXPORT_OK = qw(diag fctres fctinfo fctOpenQA::Log::warn  fcterr );

use backend::driver;
require IPC::System::Simple;
use autodie ':all';
use OpenQA::Log;

sub mydie;

$| = 1;


our $default_timeout = 30;    # assert timeout, 0 is a valid timeout
our $idle_timeout    = 19;    # wait_idle 0 makes no sense

my @ocrrect;

our $screenshotpath = "qemuscreenshot";

# global vars

our $logfd;

our $istty;
our $direct_output;

# Known locations of OVMF (UEFI) firmware: first is openSUSE, second is
# the kraxel.org nightly packages, third is Fedora's edk2-ovmf package.
our @ovmf_locations = ('/usr/share/qemu/ovmf-x86_64-ms.bin', '/usr/share/edk2.git/ovmf-x64/OVMF_CODE-pure-efi.fd', '/usr/share/edk2/ovmf/OVMF_CODE.fd');

our %vars;

sub load_vars() {
    my $fn  = "vars.json";
    my $ret = {};
    local $/;
    open(my $fh, '<', $fn) or OpenQA::Log::die("Can't open '$fn'");
    eval { $ret = JSON->new->relaxed->decode(<$fh>); };
    OpenQA::Log::die("parse error in vars.json: $@") if $@;
    close($fh);
    %vars = %{$ret};
    return;
}

sub save_vars() {
    my $fn = "vars.json";
    unlink "vars.json" if -e "vars.json";
    open(my $fd, ">", $fn);
    flock($fd, LOCK_EX) or OpenQA::Log::die("cannot lock vars.json: $!");
    truncate($fd, 0) or OpenQA::Log::die("cannot truncate vars.json: $!");

    # make sure the JSON is sorted
    my $json = JSON->new->pretty->canonical;
    print $fd $json->encode(\%vars);
    close($fd);
    return;
}

sub result_dir() {
    return "testresults";
}

our $gocrbin = "/usr/bin/gocr";

# set from isotovideo during initialization
our $scriptdir;

sub init {
    load_vars();

    $bmwqemu::vars{BACKEND} ||= "qemu";

    # remove directories for asset upload
    remove_tree("assets_public");
    remove_tree("assets_private");

    remove_tree(result_dir);
    mkdir result_dir;
    mkdir join('/', result_dir, 'ulogs');

    if ($direct_output) {
        open($logfd, '>&STDERR');
    }
    else {
        open($logfd, ">", result_dir . "/autoinst-log.txt");
    }
    # set unbuffered so that send_key lines from main thread will be written
    my $oldfh = select($logfd);
    $| = 1;
    select($oldfh);

    unless ($vars{CASEDIR}) {
        OpenQA::Log::die("DISTRI undefined\n" . pp(\%vars)) unless $vars{DISTRI};
        my @dirs = ("$scriptdir/distri/$vars{DISTRI}");
        unshift @dirs, $dirs[-1] . "-" . $vars{VERSION} if ($vars{VERSION});
        for my $d (@dirs) {
            if (-d $d) {
                $vars{CASEDIR} = $d;
                last;
            }
        }
        OpenQA::Log::die("can't determine test directory for $vars{DISTRI}'") unless $vars{CASEDIR};
    }

    # defaults
    $vars{QEMUPORT} ||= 15222;
    $vars{VNC}      ||= 90;
    # openQA already sets a random string we can reuse
    $vars{JOBTOKEN} ||= random_string(10);

    # FIXME: does not belong here
    if (defined($vars{DISTRI}) && $vars{DISTRI} eq 'archlinux') {
        $vars{HDDMODEL} = "ide";
    }

    save_vars();

    ## env vars end

    ## some var checks
    if (!-x $gocrbin) {
        $gocrbin = undef;
    }
    if ($vars{SUSEMIRROR} && $vars{SUSEMIRROR} =~ s{^(\w+)://}{}) {    # strip & check proto
        if ($1 ne "http") {
            OpenQA::Log::die("only http mirror URLs are currently supported but found '$1'");
        }
    }

}

## some var checks end

# global vars end

# local vars

our $backend;    #FIXME: make local after adding frontend-api to bmwqemu

# local vars end

# global/shared var set functions

sub set_ocr_rect {
    @ocrrect = @_;
    return;
}

# global/shared var set functions end

# util and helper functions

# sub  {
#     local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
#     OpenQA::Log::(@_);
# }

# sub diag {
#     local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
#     OpenQA::Log::info(@_);
#     return;
# }

# sub  {
#     my ($text) = @_;
#     local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
#     OpenQA::Log::debug("$text");
#     return;
# }

# sub fctres {
#     my ($text) = @_;
#     local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
#     OpenQA::Log::info(">>> $text");
#     return;
# }

# sub fctinfo {
#     my ($text) = @_;
#     local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
#     OpenQA::Log::info("::: $text");
#     return;
# }

# sub fctOpenQA::Log::warn {
#     my ($text) = @_;
#     local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
#     OpenQA::Log::OpenQA::Log::warn("!!! $text");
#     return;
# }

# sub fcterr {
#     my ($text) = @_;
#     local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
#     OpenQA::Log::error("EEE $text");
#     return;
# }

sub modstart {
    my $text = sprintf "Test module: %s at %s", join(' ', @_), POSIX::strftime("%F %T", gmtime);
    local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
    OpenQA::Log::info($text);
    return;
}

use autotest '$current_test';
sub current_test() {
    return $autotest::current_test;
}

sub update_line_number {
    return unless current_test;
    my $out    = "";
    my $ending = quotemeta(current_test->{script});
    for my $i (1 .. 10) {
        my ($package, $filename, $line, $subroutine, $hasargs, $wantarray, $evaltext, $is_require, $hints, $bitmask, $hinthash) = caller($i);
        last unless $filename;
        next unless $filename =~ m/$ending$/;
        OpenQA::Log::debug("$filename:$line called $subroutine");
        last;
    }
    return;
}

# pretty print like Data::Dumper but without the "VAR1 = " prefix
sub pp {
    # FTR, I actually hate Data::Dumper.
    my $value_with_trailing_newline = Data::Dumper->new(\@_)->Terse(1)->Dump();
    chomp($value_with_trailing_newline);
    return $value_with_trailing_newline;
}

=head2 log_call

    log_call method will write the name of the fuction that actually triggered the call in testapi,
    calls that are using log_call from testapi, will have the following syntax on logfiles: B<::: <<<>

=cut

sub log_call {
    my $fname = (caller(1))[3];
    local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 2;
    update_line_number();
    my @result;
    while (my ($key, $value) = splice(@_, 0, 2)) {
        push @result, join("=", $key, pp($value));
    }

    my $params = join(", ", @result);
    OpenQA::Log::info('<<< ' . $fname . "($params)");
    return;
}

sub fileContent {
    my ($fn) = @_;
    no autodie 'open';
    open(my $fd, "<", $fn) or return;
    local $/;
    my $result = <$fd>;
    close($fd);
    return $result;
}

# util and helper functions end

# backend management

sub stop_vm() {
    return unless $backend;
    my $ret = $backend->stop();
    if (!$direct_output && $logfd) {
        close $logfd;
        $logfd = undef;
    }
    return $ret;
}

# runtime information gathering functions end

# store the obj as json into the given filename
sub save_json_file {
    my ($result, $fn) = @_;

    open(my $fd, ">", "$fn.new");
    print $fd to_json($result, {pretty => 1});
    close($fd);
    return rename("$fn.new", $fn);
}

sub scale_timeout {
    my ($timeout) = @_;
    return $timeout * ($vars{TIMEOUT_SCALE} // 1);
}

=head2 random_string

  random_string([$count]);

Just a random string useful for pseudo security or temporary files.
=cut

sub random_string {
    my ($count) = @_;
    $count //= 4;
    my $string;
    my @chars = ('a' .. 'z', 'A' .. 'Z');
    $string .= $chars[rand @chars] for 1 .. $count;
    return $string;
}

sub hashed_string {
    OpenQA::Log::OpenQA::Log::warn('@DEPRECATED: Use testapi::hashed_string instead');
    return testapi::hashed_string(@_);
}

sub wait_for_one_more_screenshot {
    # sleeping for one second should ensure that one more screenshot is taken
    sleep 1;
}

1;

# vim: set sw=4 et:
