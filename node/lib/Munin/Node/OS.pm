package Munin::Node::OS;

# $Id$

use warnings;
use strict;

use Carp;
use English qw(-no_match_vars);

use Munin::Node::Config;
use Munin::Common::Timeout;

use POSIX ();

sub get_uid {
    my ($class, $user) = @_;
    return $class->_get_xid($user, \&POSIX::getpwnam, \&POSIX::getpwuid);
}


sub get_gid {
    my ($class, $group) = @_;
    return $class->_get_xid($group, \&POSIX::getgrnam, \&POSIX::getgrgid);
}

sub _get_xid {
    my ($class, $entity, $name2num, $num2name) = @_;
    return unless defined $entity;

    if ($entity =~ /^\d+$/) {
        return unless $num2name->($entity); # Entity does not exist
        return $entity;
    } else {
        return $name2num->($entity);
    }
}


sub get_fq_hostname {
    my ($class) = @_;

    my $hostname = eval {
        require Sys::Hostname;
        return (gethostbyname(Sys::Hostname::hostname()))[0];
    };
    return $hostname if $hostname;

    $hostname = `hostname`;
    chomp($hostname);
    $hostname =~ s/\s//g;
    return $hostname;
}


#FIX needs a better name
sub check_perms {
    my ($class, $target) = @_;
    my @stat;

    my $config = Munin::Node::Config->instance();

    return unless defined $target;
    return 1 unless $config->{paranoia};

    unless (-e "$target")    {
	warn "Failed to check permissions on nonexistent target: '$target'";
	return;
    }

    my ($mode, $uid, $gid) = (stat $target)[2,4,5];
    if ($uid != 0 || ($gid != 0 && ($mode & oct(20))) || ($mode & oct(2))) {
	warn sprintf(
            "Warning: '$target' has dangerous permissions (%04o)",
            $mode & oct(7777),
        );
	return;
    }

    # Check dir as well
    if (-f "$target") {
	(my $dirname = $target) =~ s/[^\/]+$//;
	return $class->check_perms($dirname);
    }

    return 1;
}

sub bitsof {
    my ($vec) = @_;

    my $bits = unpack("b*", $vec);
    
    return $bits;
}



sub read_from_child {
    # Read stuff from the file handles connected to the pluginds
    # stdout and stderr.

    my ($self, $stdout, $stderr) = @_;

    my ($rout, $wout, $eout);

    my $rin = my $win = my $ein = '';

    my $output = my $errput = '';

    vec($win,0,1)=0;
    
    vec($rin,fileno($stdout),1) = 1;
    vec($rin,fileno($stderr),1) = 1;

    $ein = $rin | $win;

    while (1) {
	# print STDERR "In read loop for plugin: read ",bitsof($rin),
	# " - write ",bitsof($win)," - exceptions ",bitsof($ein),"\n";

 	my $nfound = select($rout=$rin, $wout=$win, $eout=$ein, undef);
	# print STDERR "Found: $nfound read ",bitsof($rout),
	# " - write ",bitsof($wout)," - exceptions ",bitsof($eout),"\n";
	
	if ($nfound == -1) {
	    # !  Print error somewhere?
	    last;
	}
	if ($nfound == 0) {
	    # Exit but no error
	    last;
	}

	if (vec($rout,fileno($stdout),1)) {
	    # print STDERR "Atempting to read from plugins stdout\n";
	    my $res = sysread($stdout,$output,4096,length($output));
	    print STDERR "Read $res bytes from plugin stdout\n";
	    next if $res;
	}
	if (vec($rout,fileno($stderr),1)) {
	    # print STDERR "Atempting to read from plugins stderr\n";
	    my $res = sysread($stderr,$errput,4096,length($errput));
	    print STDERR "Read $res bytes from plugin stderr\n";
	    next if $res;
	}

	# We are at the end so there was nothing to read this time.
	# Since we are not using a timeout that must mean that something
	# else happened.  We'll assume that this is the end.
	last;
    }

    my @output = split (/[\r\n]+/,$output);
    my @errors = split (/[\r\n]+/,$errput);

    return (\@output,\@errors);
}


# NOTE:
#
# Since each pipe is only read from once, the child will block 
# (and eventually time out) if it tries to print more data to 
# either filehandle than the corresponding pipe's capacity.
#
# POSIX requires PIPE_BUF to be >=512 bytes, which should be
# sufficient for even the most verbose plugins.  In any case,
# most recent Unices seem to provide at least a whole page
# (usually 4kB).
sub run_as_child
{
    my ($self, $timeout, $code, @args) = @_;

    pipe my ($out_read, $out_write)
        or carp "Error creating stdout pipe: $!";
    pipe my ($err_read, $err_write)
        or carp "Error creating stderr pipe: $!";

    if (my $pid = fork) {
        # In parent
        close $out_write; close $err_write;

	my $out;
	my $err;

        # Give the child till the timeout to finish up
        my $read_it_and_reap = sub { 
	    ($out,$err) = $self->read_from_child($out_read,$err_read);
	    waitpid($pid, 0);
	};

        my $timed_out = !do_with_timeout($timeout, $read_it_and_reap);

        Munin::Node::OS->reap_child_group($pid)
	    if $timed_out;

        close $out_read; close $err_read;

        return {
            stdout => $out,
            stderr => $err,
            retval => $?,
            timed_out => $timed_out,
        };
    }
    elsif (defined $pid) {
        # In child
        close $out_read; close $err_read;

        POSIX::setsid();

        # use the pipes to replace STD{OUT,ERR}
        open(STDOUT, '>&=', fileno($out_write));
        open(STDERR, '>&=', fileno($err_write));

        exit $code->(@args);
    }
    else {
        # oops.
        carp "Unable to fork: $!";
    }
}


sub reap_child_group {
    my ($class, $child_pid) = @_;

    return unless $child_pid;
    return unless $class->possible_to_signal_process($child_pid);
    
    # Negative number signals the process group
    kill -1, $child_pid;           # SIGHUP
    sleep 2; 
    kill -9, $child_pid;           # SIGKILL
}


sub possible_to_signal_process {
    my ($class, $pid) = @_;

    return kill (0, $pid);
}


sub set_effective_user_id {
    my ($class, $uid) = @_;

    $class->_set_xid(\$EFFECTIVE_USER_ID, $uid);
}


sub set_real_user_id {
    my ($class, $uid) = @_;

    $class->_set_xid(\$REAL_USER_ID, $uid);
}


sub set_effective_group_id {
    my ($class, $gid) = @_;

    $class->_set_xid(\$EFFECTIVE_GROUP_ID, $gid);
}


sub set_real_group_id {
    my ($class, $gid) = @_;

    $class->_set_xid(\$REAL_GROUP_ID, $gid);
}


sub _set_xid {
    my ($class, $x, $id) = @_;
    
    # According to pervar manpage, assigning to $<, $> etc results in
    # a system call. So we need to check $! for errors.
    $! = undef;
    $$x = $id;
    croak $! if $!;
}


1;

__END__

=head1 NAME

Munin::Node::OS - OS related utility methods for the munin node.


=head1 SYNOPSIS

 use Munin::Node::OS;
 my $uid  = Munin::Node::OS->get_uid('foo');
 my $host = Munin::Node::OS->get_fq_hostname();

=head1 METHODS

=over

=item B<get_uid>

 $uid = $class->get_uid($user)

Returns the user ID. $user might either be a user name or a user
ID. Returns undef if the user is nonexistent.

=item B<get_gid>

 $gid = $class->get_gid($group)

Returns the group ID. $group might either be a group name or a group
ID. Returns undef if the group is nonexistent.

=item B<get_fq_hostname>

 $host = $class->get_fq_hostname()

Returns the fully qualified host name of the machine.

=item B<check_perms>

 $bool = $class->check_perms($target);

If paranoia is enabled, returns false unless $target is owned by root,
and has safe permissions.  If $target is a file, also checks the
directory it inhabits.

=item B<run_as_child>

  $result = run_as_child($timeout, $coderef, @arguments);

Creates a child process to run $code and waits for up to 
$timeout seconds for it to complete.  Returns a hashref
containg the following keys:

=over

=item C<stdout>, C<stderr>

Array references containing the output of these filehandles;

=item C<retval>

The result of wait();

=item C<timed_out>

True if the child had to be interrupted.

=back

System errors will cause it to carp.


=item B<reap_child_group>

 $class->reap_child_group($pid);

Sends SIGHUP and SIGKILL to the process group identified by $pid.

Sleeps for 2 seconds between SIGHUP and SIGKILL.

=item B<possible_to_signal_process>

 my $bool = $class->possible_to_signal_process($pid)

Check whether it’s possible to send a signal to $pid (that means, to
be brief, that the process is owned by the same user, or we are the
super-user).  This is a useful way to check that a child process is
alive (even if only as a zombie) and hasn’t changed its UID.

=item B<set_effective_user_id>

 eval {
     $class->set_effective_user_id($uid);
 };
 if ($@) {
     # Failed to set EUID
 }

The name says it all ...

=item B<set_effective_group_id>

See documentation for set_effective_user_id()

=item B<set_real_user_id>

See documentation for set_effective_user_id()

=item B<set_real_group_id>

See documentation for set_effective_user_id()

=back

=cut
