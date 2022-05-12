#!/bin/bash
#
# A script to collect tcpdumps of traffic between two pods/nodes.
# Currently only tested on OpenShift 4.x / OpenShiftSDN.
#
# DO NOT RUN IN PRODUCTION
#
# Following is the workflow:
#   1- Create "serving" pod on the first node running a minimal (python) http server.
#   2- Create "client" pod on the second node that will be used to curl the first pod.
#   3- Create "host-capture" pods on each node to capture host network traffic (tun0, veth etc.)
#   4- Send start signal to the pods that will trigger them to start simulating traffic (curl)
#      and collecting tcpdumps from the relevant interfaces.
#   5- Wait for the duration defined.
#   6- Send stop signal to the pods that will trigger the pods to stop the simulation/collection.
#   7- Collect the collected logs.
#
# Following log files are collected from each node:
#   *-pod-tcpdump.pcap: tcpdump of eth0 interface from inside the pod.
#   veth*-tcpdump.pcap: tcpdump of the serving/client pod from the host interface.
#   tun0-tcpdump.pcap: tcpdump of tun0 interface on the hosts.
#   *-def_int-tcpdump.pcap: tcpdump of default interface on the hosts.
#   ovs-info.txt: ovs bridge and flows on the hosts.
#   web-server.log: Python webserver logs for each curl received.
#   curl.log: verbose curl ouptut for each curl call
#   *.run.log files: Runtime info from the pods/scripts.
#   iflink_*: iflink number of the pod interface (ignore)
#   
# Author: Khizer Naeem (knaeem@redhat.com)
# 14 Aug 2021

export SDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

err() {
    echo; echo;
    echo -e "\e[97m\e[101m[ERROR]\e[0m ${1}"; shift; echo;
    while [[ $# -gt 0 ]]; do echo "    $1"; shift; done
    echo; exit 1;
}


while [[ $# -gt 0 ]]
do
key="$1"
case $key in
    -s|--serving-node)
    S_NODE="$2"
    shift
    shift
    ;;
    -s=*|--serving-node=*)
    S_NODE="${key#*=}"
    shift
    ;;
    -c|--client-node)
    C_NODE="$2"
    shift
    shift
    ;;
    -c=*|--client-node=*)
    C_NODE="${key#*=}"
    shift
    ;;
    -d|--duration)
    DURATION="$2"
    shift
    shift
    ;;
    -d=*|--duration=*)
    DURATION="${key#*=}"
    shift
    ;;
    -p|--project)
    PROJECT_NAME="$2"
    shift
    shift
    ;;
    -p=*|--project=*)
    PROJECT_NAME="${key#*=}"
    shift
    ;;
    --image)
    IPERF_IMAGE="$2"
    shift
    shift
    ;;
    --image=*)
    IPERF_IMAGE="${key#*=}"
    shift
    ;;
    --interface)
    INTERFACE="$2"
    shift
    shift
    ;;
    --interface=*)
    INTERFACE="${key#*=}"
    shift
    ;;
    --network)
    NET="$2"
    shift
    shift
    ;;
    --network=*)
    NET="${key#*=}"
    shift
    ;;
    -u|--udp)
    UDP="-u -b 0"
    shift
    ;;
    -h|--help)
    SHOW_HELP="yes"
    shift
    ;;
    -y|--yes)
    YES="yes"
    shift
    ;;
    *)
    echo "ERROR: Invalid argument $key"
    exit 1
    ;;
esac
done

# Show help if -h/--help is passed
if [ -n "${SHOW_HELP}" ]; then
    cat "${SDIR}/README.txt" 2> /dev/null \
        || echo "See: https://github.com/kxr/openshift-iperf"
    exit 0
fi

# Set default node network if not set
if [ -z "${NET}" ]; then
    NET="node"
fi

# Set the default project name if not set
if [ -z "${PROJECT_NAME}" ]; then
    echo "===> Setting default project name:"
    PROJECT_NAME="iperf-test"
    echo "Done (${PROJECT_NAME})"
    echo
fi

# Random node selection if not set
if [ -z "${S_NODE}" -o -z "${C_NODE}" ]; then
    
    READY_NODES=($(oc get nodes -o 'go-template={{range .items}}{{$ready:=""}}{{range .status.conditions}}{{if eq .type "Ready"}}{{$ready = .status}}{{end}}{{end}}{{if eq $ready "True"}}{{.metadata.name}}{{" "}}{{end}}{{end}}'))
    READY_NODES=(${READY_NODES[@]/$S_NODE})
    READY_NODES=(${READY_NODES[@]/$C_NODE})
    test "${#READY_NODES[@]}" -lt "1" && err "Not enough ready node(s) found!"

    # Pick random serving node if not set
    if [ -z "${S_NODE}" ]; then
        echo "===> Selecting random serving node:"
        S_NODE=${READY_NODES[ $RANDOM % ${#READY_NODES[@]} ]}
        READY_NODES=(${READY_NODES[@]/$S_NODE})
        echo "Done (${S_NODE})"
        echo
    fi

    # Pick random client node if not set
    if [ -z "${C_NODE}" ]; then
        echo "===> Selected random client node:"
        C_NODE=${READY_NODES[ $RANDOM % ${#READY_NODES[@]} ]}
        echo "Done (${C_NODE})"
        echo
    fi
fi

echo "===> Running iperf test on ${NET^^} network using interface/IP:"
# Set node IP if not set
if [ ${NET,,} == "node" ]; then
    HOST_NETWORK="true"
    if [ -z "${INTERFACE}" ]; then
        IP=$(oc get nodes ${S_NODE} -o jsonpath='{.status.addresses[?(.type=="InternalIP")].address}') \
            || err "Failed to get IP for node ${S_NODE}"
        echo "${IP}"
    else
        echo "${INTERFACE}"
    fi
elif [ ${NET,,} == "pod" ]; then
    INTERFACE="eth0"
    echo "${INTERFACE}"
    HOST_NETWORK="false"
else
    err "Unknown network ${NET}. Set it to pod or node."
fi
echo


# Set default duration if not set
if [ -z "${DURATION}" ]; then
    echo "===> Setting default testing duration (in seconds):"
    DURATION="60"
    echo "Done (${DURATION})"
    echo

fi

# Set default image if not set
if [ -z "${IPERF_IMAGE}" ]; then
    echo "===> Setting default network-tools image:"
    IPERF_IMAGE="quay.io/kxr/iperf3"
    echo "Done (${IPERF_IMAGE})"
    echo
fi

# Timestamp
TS=$(date +%d%h%y-%H%M%S)
# Directory variables should not have / at the end
DIR_NAME="${PROJECT_NAME}-${TS}"
HOST_TMPDIR="/host/tmp/${DIR_NAME}"


# Ensure we can make new directory
mkdir "${DIR_NAME}" && rmdir "${DIR_NAME}" \
    || err "Cannot make new directory in current working directory!"

# Ensure oc binary is present
builtin type -P oc &> /dev/null \
    || err "oc not found"

# Ensure oc is authenticated
OC_USER=$(oc whoami 2> /dev/null) \
    || err "oc not authenticated"

# Ensure nodes are present and ready
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
    oc get node "${node}" &> /dev/null \
        || err "Node ${node} not found!"
    ready=$(oc get node ${node} -o jsonpath='{.status.conditions[?(@.type == "Ready")].status}')
    test "$ready" = "True" \
        || err "Node ${node} not Ready!"
done

# Ensure that current user can create project
oc auth can-i create project &> /dev/null \
    || err "Current user (${OC_USER}) cannot create subscription in ns/openshift-operators"

# Show summary of selection
echo "===> Summary:"
echo
echo
echo -e "\tNETWORK:         ${NET^^}"
echo -e "\tSERVING NODE:    ${S_NODE}"
echo -e "\tCLIENT NODE:     ${C_NODE}"
echo -e "\tPROJECT NAME:    ${PROJECT_NAME}"
echo -e "\tTEST DURATION:   ${DURATION}"
echo -e "\tCONTAINER IMAGE: ${IPERF_IMAGE}"
echo -e "\tTIME STAMP:      ${TS}"
echo
echo

# Check if we can continue
if [ -z "${YES}" ]; then
    echo
    echo -n "Press [Enter] to continue, [Ctrl]+C to abort: "
    read userinput;
    echo
fi


# Create/Use project
if oc get project "${PROJECT_NAME}" -o name &> /dev/null; then
    echo "===> Using existing project (${PROJECT_NAME}):"
    oc project "${PROJECT_NAME}" || err "Error using project ${PROJECT_NAME}"
else
  echo "===> Creating new project (${PROJECT_NAME}):"
  oc new-project "${PROJECT_NAME}" &> /dev/null \
      || err "Error creating new project ${PROJECT_NAME}"
  echo "Done (${PROJECT_NAME})"
fi
echo

# Add privileges to default sa
echo "===> Adding privileges to default service account"
oc adm policy add-scc-to-user privileged -z default -n ${PROJECT_NAME} &> /dev/null \
    || err "Cannot add privleged scc to default service account"
oc adm policy add-scc-to-user hostnetwork -z default -n ${PROJECT_NAME} &> /dev/null \
    || err "Cannot add hostnetwork scc to default service account"
echo "Done (scc: hostnetwork)"
echo

# Serving Pod on Serving Node
S_POD="iperf-${TS,,}-server"
echo "===> Creating serving pod on ${S_NODE}:"
cat <<EOF | oc create -f - 
apiVersion: v1
kind: Pod
metadata:
  name: ${S_POD}
  namespace: ${PROJECT_NAME} 
spec:
  nodeName: ${S_NODE}
  hostNetwork: ${HOST_NETWORK}
  hostPID: true
  restartPolicy: Never
  containers:
  - name: server
    image: ${IPERF_IMAGE}
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
      runAsUser: 0
    command:
    - bash
    - -c
    - |
      if [ -z "${IP}" ]; then LIP=\$(ip address show dev ${INTERFACE} | grep -w -m1 "inet" | sed 's/\s*inet\s*\([0-9.]*\)\/.*/\1/'); fi
      if [ -n "${IP}" ]; then LIP="${IP}"; fi
      if [ -z "\${LIP}" ]; then echo "Failed to determine IP of ${INTERFACE}"; exit 1; fi
      echo "\${LIP}" | tee /tmp/IP
      iperf3 -i 5 -s --one-off -B \${LIP}
EOF
test "$?" -eq "0" || err "Failed creating serving pod"
echo

echo "===> Waiting for serving pod (${S_POD}) to become ready:"
while true; do
    phase=$(oc get pod/${S_POD} -o jsonpath='{.status.phase}' 2> /dev/null)
    if [ ${phase} == "Running" ]; then
        break
    fi
    if [ ${phase} == "Failed" ]; then
        err "Serving pod failed. See: oc logs ${S_POD} -n ${PROJECT_NAME}"
    fi
    sleep 5
done
oc wait --timeout="1h" -n ${PROJECT_NAME} --for=condition=Ready pod/${S_POD} \
    || err "Timed out waiting for serving pod to become ready"
echo

# Collect the IP Address that we bind in iperf
echo "===> Collecting binding IP:"
SIP=$(oc exec pod/${S_POD} -- cat /tmp/IP) \
  || err "Failed to get the binding IP (/tmp/IP) from pod/${S_POD}"
echo "Done (${SIP})"

# Client Pod on Client Node
C_POD="iperf-${TS,,}-client"
echo "===> Creating client pod on ${C_NODE}:"
cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${C_POD}
  namespace: ${PROJECT_NAME} 
spec:
  nodeName: ${C_NODE}
  hostNetwork: ${HOST_NETWORK}
  hostPID: true
  restartPolicy: Never
  containers:
  - name: client
    image: ${IPERF_IMAGE}
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
      runAsUser: 0
    command:
    - bash
    - -c
    - |
      iperf3 -i 5 -t 60 ${UDP} --forceflush -c ${SIP}
      exit 0
EOF
test "$?" -eq "0" || err "Failed creating client pod"
echo
echo "===> Waiting for client pod (${C_POD}) to become ready:"
while true; do
    phase=$(oc get pod/${C_POD} -o jsonpath='{.status.phase}' 2> /dev/null)
    if [ ${phase} == "Running" ]; then
        break
    fi
    if [ ${phase} == "Failed" ]; then
        err "Client pod failed. See: oc logs ${C_POD} -n ${PROJECT_NAME}"
    fi
    sleep 2
done
oc wait --timeout="1h" -n ${PROJECT_NAME} --for=condition=Ready pod/${C_POD} \
    || err "Timed out waiting for serving pod to become ready"
echo

echo "================================"
echo
oc logs -f pod/${C_POD} -n ${PROJECT_NAME}