# Copyright © 2016 SUSE LLC
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
package consoles::virtio_screen;
use 5.018;
use warnings;
use English qw( -no_match_vars );
use Time::HiRes qw( gettimeofday usleep );
use integer;

our $VERSION;

sub new {
    my ($class, $socket_fd) = @_;
    my $self = bless {class => $class}, $class;
    $self->{socket_fd} = $socket_fd;
    return $self;
}

my $trying_to_use_keys = <<'FIN.';
Virtio terminal does not support send_key. Use type_string (possibly with an
ANSI/XTERM escape sequence), or switch to a console which sends key presses, not
terminal codes.
FIN.

=head2 send_key

    send_key(key => 'ret');

This is mostly redundant for the time being, use C<type_string> instead. Many testapi
functions use C<send_key('ret')> however so that particular case has been implemented.
In the future this could be extended to provide more key name to terminal code
mappings.

=cut
sub send_key {
    my ($self, $nargs) = @_;

    if ($nargs->{key} eq 'ret') {
        $nargs->{text} = "\n";
        $self->type_string($nargs);
    }
    else {
        die $trying_to_use_keys;
    }
}

sub hold_key {
    die $trying_to_use_keys;
}

sub release_key {
    die $trying_to_use_keys;
}

=head2 type_string

    type_string($self, $message, terminate_with => '');

Writes $message to the socket which the guest's terminal is listening on. Unlike
VNC based consoles we just send the bytes making up $message not a series of
keystrokes. This is much faster, but means that special key combinations like
Ctrl-Alt-Del or SysRq[1] may not be possible. However most terminals do support
many escape sequences for scrolling and performing various actions other
than entering text. See C0, C1, ANSI, VT100 and XTERM escape codes.

The optional terminate_with argument can be set to EOT (End Of Transmission),
ETX (End Of Text). Sending EOT should have the same effect as pressing Ctrl-D
and ETX is the same as pressing Ctrl-C on a terminal. EOT is sent twice, because
it appeared that sending it once had no effect when used with `cat`.

[1] It appears sending 0x0f will press the SysRq key down on hvc based consoles.

=cut
sub type_string {
    my ($self, $nargs) = @_;
    my $fd = $self->{socket_fd};

    bmwqemu::log_call(%$nargs);

    my $text = $nargs->{text};
    my $term;
    for ($nargs->{terminate_with} || '') {
        if    (/^ETX$/) { $term = "\cC"; }       #^C, Ctrl-c, End Of Text
        elsif (/^EOT$/) { $term = "\cD\cD"; }    #^D, Ctrl-d, End Of Transmission
    }

    $text .= $term if defined $term;
    my $written = syswrite $fd, $text;
    unless (defined $written) {
        die "Error writing to virtio terminal: $ERRNO";
    }
    if ($written < length($text)) {
        die "Was not able to write entire message to virtio terminal. Only $written of $nargs->{text}";
    }
}

sub get_elapsed {
    no integer;
    my $start = shift;
    return gettimeofday() - $start;
}

# If $pattern is an array of regexes combine them into a single one.
# If $pattern is a single string, wrap it in an array.
# Otherwise leave as is.
sub normalise_pattern {
    my ($pattern, $no_regex) = @_;

    if (ref $pattern eq 'ARRAY' && !$no_regex) {
        my $hr = shift @$pattern;
        if (@$pattern > 0) {
            my $re = qr/($hr)/;
            for my $r (@$pattern) {
                $re .= qr/|($r)/;
            }
            return $re;
        }
        return $hr;
    }

    if ($no_regex && ref $pattern ne 'ARRAY') {
        return [$pattern];
    }

    return $pattern;
}

=head2 read_until

  read_until($self, $pattern, $timeout, [
                     buffer_size => 4096, record_output => 0, exclude_match => 0,
                     no_regex => 0
  ]);

Monitor the virtio console socket $file_descriptor for a character sequence which matches
$pattern. Bytes are read from the socket in up to $buffer_size chunks and each chunk is
added to a ring buffer which is also up to $buffer_size long. The regular expression is tested
against the ring buffer after each read operation. Note, the reason we are using a ring
buffer is to avoid matches failing because the matching text is split between two reads.

If $record_output is set then all data from the socket is stored in a separate string and returned.
Otherwise just the contents of the ring buffer will be returned. Setting $exclude_match removes the
matched string from the returned string. Data which was received after a matching set of characters
is lost unless data from the socket is being logged to a file.

Setting $no_regex will cause it to do a plain string search using index().

Returns a map reference like { matched => 1, string => 'text from the terminal' } on success
and { matched => 0, string => 'text from the terminal' } on failure.

=cut
sub read_until {
    my ($self, $pattern, $timeout) = @_[0 .. 2];
    my $fd       = $self->{socket_fd};
    my %nargs    = @_[3 .. $#_];
    my $buflen   = $nargs{buffer_size} || 4096;
    my $overflow = $nargs{record_output} ? '' : undef;
    my $sttime   = gettimeofday;
    my ($rbuf, $buf) = ('', '');
    my $loops = 0;
    my ($prematch, $match);
    my $do_while_idle = $nargs{do_while_idle};

    my $re = normalise_pattern($pattern, $nargs{no_regex});

    $nargs{pattern} = $re;
    $nargs{timeout} = $timeout;
    bmwqemu::log_call(%nargs);

  READ: while (1) {
        $loops++;

        if (get_elapsed($sttime) >= $timeout) {
            return {matched => 0, string => ($overflow || '') . $rbuf};
        }

        my $read = sysread($fd, $buf, $buflen / 2);
        unless (defined $read) {
            if ($ERRNO{EAGAIN} || $ERRNO{EWOULDBLOCK}) {
                &$do_while_idle() if defined $do_while_idle;
                next READ;
            }
            die "Failed to read from virtio console char device: $ERRNO";
        }

        # If there is not enough free space in the ring buffer; remove an amount
        # equal to the bytes just read minus the free space in $rbuf from the
        # begining. If we are recording all output, add the removed bytes to
        # $overflow.
        if (length($rbuf) + $read > $buflen) {
            my $remove_len = $read - ($buflen - length($rbuf));
            if (defined $overflow) {
                $overflow .= substr $rbuf, 0, $remove_len;
            }
            $rbuf = substr $rbuf, $remove_len;
        }
        $rbuf .= $buf;

        # Search ring buffer for a match and exit if we find it
        if ($nargs{no_regex}) {
            for my $p (@$re) {
                my $i = index($rbuf, $p);
                if ($i >= 0) {
                    $match = substr $rbuf, $i, length($p);
                    $prematch = substr $rbuf, 0, $i;
                    last READ;
                }
            }
        }
        elsif ($rbuf =~ m/$re/) {
            # See match variable perf issues: http://bit.ly/2dbGrzo
            $prematch = substr $rbuf, 0, $LAST_MATCH_START[0];
            $match = substr $rbuf, $LAST_MATCH_START[0], $LAST_MATCH_END[0] - $LAST_MATCH_START[0];
            last READ;
        }
    }

    my $elapsed = get_elapsed($sttime);
    bmwqemu::fctinfo("Matched output from SUT in $loops loops & $elapsed seconds: $match");

    $overflow ||= '';
    if ($nargs{exclude_match}) {
        return $overflow . $prematch;
    }
    return {matched => 1, string => $overflow . $prematch . $match};
}

sub current_screen {
    return 0;
}

sub request_screen_update {
    return;
}

1;
