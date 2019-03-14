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

# this is just a stupid console to track if we're connected to the host
# it is used in s390x backend for serial connection

package consoles::sshIucvconn;

use strict;
use warnings;
use autodie ':all';

use base 'consoles::network_console';

use testapi 'get_var';

sub connect_remote {
    my ($self, $args) = @_;
    my $hostname = $args->{hostname};
    my $zvmguest = get_var('ZVM_GUEST');

    # ssh connection to SUT for agetty
    my $ttyconn = $self->backend->new_ssh_connection(hostname => $hostname, password => $args->{password}, username => 'root');

    # start agetty to ensure that iucvconn is not killed
    my $chan = $ttyconn->channel() || $ttyconn->die_with_error();

    $chan->blocking(0);
    $chan->pty(1);

    $chan->exec("smart_agetty hvc0") || $ttyconn->die_with_error("Unable to execute smart_agetty hvc0");
    # Save objects to prevent unexpected closings
    $self->{ttychan} = $chan;
    $self->{ttyconn} = $ttyconn;

    # ssh connection to SUT for iucvconn
    my ($ssh, $serialchan) = $self->backend->start_ssh_serial(hostname => $args->{hostname}, password => $args->{password}, username => 'root');
    # start iucvconn
    $serialchan->exec("iucvconn $zvmguest lnxhvc0") || $ssh->die_with_error('Unable to execute iucvconn command');
}

# to be called on reconnect
sub kill_ssh {
    my ($self) = @_;

    $self->backend->stop_ssh_serial;
}

sub screen {
    # we have no screen
    return;
}

1;
