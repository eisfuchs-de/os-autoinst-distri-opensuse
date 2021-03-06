# SUSE's openQA tests
#
# Copyright © 2018 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: run InfiniBand test suite hpc-testing
#
# Maintainer: Michael Moese <mmoese@suse.de, Nick Singer <nsinger@suse.de>

use base 'opensusebasetest';
use strict;
use testapi;
use utils;
use power_action_utils 'power_action';
use lockapi;
use Utils::Backends 'use_ssh_serial_console';
use ipmi_backend_utils;


our $master;
our $slave;

sub check_dmesg {
    my $dmesg_cmd = 'dmesg';
    if ($1) {
        $dmesg_cmd = "cat $1";
    }
    assert_script_run(
        "dmesg_cmd | grep -q \
        -e \"kernel BUG at\" \
        -e \"WARNING:\" \
	-e \"BUG:\" \
	-e \"Oops:\" \
	-e \"possible recursive locking detected\" \
	-e \"Internal error\" \
	-e \"INFO: suspicious RCU usage\" \
	-e \"INFO: possible circular locking dependency detected\" \
        -e \"general protection fault:\""
    );
}

sub ibtest_slave {
    # setup complete, test can begin
    barrier_wait('IBTEST_BEGIN');

    # wait until test is finished
    barrier_wait('IBTEST_DONE');

    # just save the dmesg log
    script_run("dmesg > /tmp/dmesg.txt");
    upload_logs("/tmp/dmesg.txt");

    # check dmesg for warnings etc.
    check_dmesg;
}

sub ibtest_master {
    my $master             = get_required_var('IBTEST_IP1');
    my $slave              = get_required_var('IBTEST_IP2');
    my $hpc_testing        = get_var('IBTEST_GITTREE', 'https://gitlab.suse.de/NMoreyChaisemartin/hpc-testing.git');
    my $hpc_testing_branch = get_var('IBTEST_GITBRANCH', 'master');

    # do all test preparations and setup
    zypper_call('ar -f -G ' . get_required_var('DEVEL_TOOLS_REPO'));
    zypper_call('--gpg-auto-import-keys ref');
    zypper_call('in git-core twopence bc');

    # create symlinks, the package is (for now) broken
    assert_script_run('ln -sf /usr/lib64/libtwopence.so.0.3.8 /usr/lib64/libtwopence.so.0');
    assert_script_run('ln -sf /usr/lib64/libtwopence.so.0.3.8 /usr/lib64/libtwopence.so');
    # pull in the testsuite
    assert_script_run("git -c http.sslVerify=false clone $hpc_testing --branch $hpc_testing_branch");

    # wait until the two machines under test are ready setting up their local things
    barrier_wait('IBTEST_BEGIN');

    assert_script_run('cd hpc-testing');
    assert_script_run("./ib-test.sh $master $slave", 1800);


    # remove non-printable characters
    script_run('tr -cd \'\11\12\15\40-\176\' < results/TEST-ib-test.xml > /tmp/results.xml');
    parse_extra_log('XUnit', '/tmp/results.xml');

    script_run("scp -o StrictHostKeyChecking=no root\@$slave:/tmp/dmesg.txt /tmp/dmesg_slave.txt");

    check_dmesg;
    check_dmesg('/tmp/dmesg_slave.txt');

    barrier_wait('IBTEST_DONE');
    barrier_destroy('IBTEST_BEGIN');
    barrier_destroy('IBTEST_DONE');
}

sub run {
    my $role = get_required_var('IBTEST_ROLE');
    $master = get_required_var('IBTEST_IP1');
    $slave  = get_required_var('IBTEST_IP2');

    use_ssh_serial_console;

    # Add the GA repository
    zypper_call("ar -f -G " . get_required_var('GA_REPO'));

    # unload firewall. MPI- and libfabric-tests require too many open ports
    script_run("systemctl stop firewalld");

    # create and distribute ssh key
    assert_script_run('ssh-keygen -b 2048 -t rsa -q -N "" -f ~/.ssh/id_rsa');
    exec_and_insert_password("ssh-copy-id -o StrictHostKeyChecking=no root\@$master");
    script_run("/usr/bin/clear");
    exec_and_insert_password("ssh-copy-id -o StrictHostKeyChecking=no root\@$slave");
    script_run("/usr/bin/clear");


    if ($role eq 'IBTEST_MASTER') {
        ibtest_master;
    }
    elsif ($role eq 'IBTEST_SLAVE') {
        ibtest_slave;
    }

    power_action('poweroff');
}

sub post_fail_hook {
    my $self = @_;
    # remove non-printable characters from the results file
    script_run('tr -cd \'\11\12\15\40-\176\' < results/TEST-ib-test.xml > /tmp/results.xml');
    parse_extra_log('XUnit', '/tmp/results.xml');

    $self->save_and_upload_log('systemctl list-units -l', '/tmp/systemd_units.log', {screenshot => 0});
}

1;

=head1 bare metal testing for InfiniBand

=head2 Overview
This test is executing an InfiniBand testsuite currently under development at SUSE.

In order to run this testsuite, three IPMI-workers are required. Two of them need 
to have actual InfiniBand HCA's, the third one is controlling the test execution.

The test has some additional dependencies. The controlling master needs to have "twopence"
(see https://github.com/openSUSE/twopence) which is not in the default SLE repositories. 
A repository needs to be specified

=head1 openQA setup

=head2 openQA worker setup
The workers with the InfiniBand HCA's need a special worker class, in this case
we assume it is "64bit-ipmi_infiniband". The third worker just needs a different 
worker class, something like "64bit-ipmi" should be fine.

=head2 openQA test suites
As the test is executed on two hosts, two test suites should be created:

=head3 ibtest-master	
ADDONURL_SDK=<addon url>
GA_REPO=<GA REPO URL>
DEVEL_TOOLS_REPO=<REPO CONTAINING RPM OF TWOPENCE>
IBTESTS=1
IBTEST_GITBRANCH=<default to master>
IBTEST_GITTREE=<default to upstream>
IBTEST_IP1=<master IP>
IBTEST_IP2=<slave IP>
IBTEST_ROLE=IBTEST_MASTER
INSTALLONLY=1
TEST=ibtest-master
WORKER_CLASS=ipmi-64bit-mlx_con5

=head3 ibtest-slave	
DEVEL_TOOLS_REPO=<REPO CONTAINING RPM OF TWOPENCE>
GA_REPO=<GA REPO URL>
IBTESTS=1
IBTEST_IP1=<master IP>
IBTEST_IP2=<slave IP>
IBTEST_ROLE=IBTEST_SLAVE
INSTALLONLY=1
PARALLEL_WITH=ibtest-master
TEST=ibtest-slave
WORKER_CLASS=ipmi-64bit-mlx_con5

