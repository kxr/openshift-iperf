
Usage: openshift-iperf.sh [OPTIONS]

Description:
A script to run iperf3 based network bandwidth test on node/pod networks.
You must be logged in to the oc command line with privileged user before
running this script.

NOTE: RUNNING BANDWIDTH TESTING IN PRODUCTION MIGHT AFFECT RUNNING WORKLOADS

Author: Khizer Naeem (kxr@redhat.com)
12 May 2022

Options:
-s, --serving-node <node-name>
    OpenShift node that will host the serving-pod for iperf.
    Default: random node

-c, --client-node <node-name>
    OpenShift node that will host the client-pod for iperf.
    Default: random node

--network [pod|node]
    Which network to test. Possible options are "pod" or "node".
    Default: node

--interface <interface>
    Specify a particular node interface to test bandwidth on.
    The interface must have an IPv4 assigned to it.
    Ignored if --network is set to pod.
    Default: Not Set

-u, --udp
    Run UDP test instead of TCP (default).

-p, --project <project-name>
    Project name that will be created to host the pods.
    Default: iperf-test

-d, --duration <duration>
    Duration in seconds to run the bandwidth test.
    Default: 60

-i, --image <image>
    Container image to be used to run the tests.
    This image must have basic bash utilities like grep, sed etc.
    And the following binaries: iperf3, ip. 
    Default: quay.io/kxr/iperf3

-y, --yes
    If this is set, script will not ask for confirmation
    Default: Not set

-h, --help
    Shows help
    Default: Not set

Examples:

# Run with default options
./openshift-iperf.sh

# Run UDP based bandwidth test
./openshift-iperf.sh --udp

# Run bandwidth test on a specific interface present on node
./openshift-iperf.sh --interface bond0

# Specify client and server nodes for bandwidth test
./openshift-iperf.sh --client-node sharedocp48-f9w4j-worker-gq96m --serving-node sharedocp48-f9w4j-master-0

# Run iperf test on pod network (eth0)
./openshift-iperf.sh --network pod