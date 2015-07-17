#!/bin/sh

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

echo "*** Setting up root ssh pubkey access across all nodes..."

# All nodes need to publish public keys, and acquire others'
$DIRNAME/setup-root-ssh.sh 1> $OURDIR/setup-root-ssh.log 2>&1

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

echo "*** Waiting for ssh access to all nodes..."

for node in $NODES ; do
    [ "$node" = "$NETWORKMANAGER" ] && continue

    SUCCESS=1
    fqdn=$node.$EEID.$EPID.$OURDOMAIN
    while [ $SUCCESS -ne 0 ] ; do
	sleep 1
	ssh -o ConnectTimeout=1 -o PasswordAuthentication=No -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=No $fqdn /bin/ls > /dev/null
	SUCCESS=$?
    done
    echo "*** $node is up!"
done

#
# Get our hosts files setup to point to the new management network.
# (These were created one-time in setup-lib.sh)
#
cat $OURDIR/mgmt-hosts > /etc/hosts
for node in $NODES 
do
    [ "$node" = "$NETWORKMANAGER" ] && continue

    fqdn="$node.$EEID.$EPID.$OURDOMAIN"
    $SSH $fqdn mkdir -p $OURDIR
    scp -p -o StrictHostKeyChecking=no \
	$SETTINGS $OURDIR/mgmt-hosts $OURDIR/mgmt-netmask \
	$OURDIR/data-hosts $OURDIR/data-netmask \
	$fqdn:$OURDIR
    $SSH $fqdn cp $OURDIR/mgmt-hosts /etc/hosts
done

echo "*** Setting up the Management Network"

if [ -z "${MGMTLAN}" ]; then
    echo "*** Building a VPN-based Management Network"

    $DIRNAME/setup-vpn.sh 1> $OURDIR/setup-vpn.log 2>&1

    # Give the VPN a chance to settle down
    PINGED=0
    while [ $PINGED -eq 0 ]; do
	sleep 2
	ping -c 1 $CONTROLLER
	if [ $? -eq 0 ]; then
	    PINGED=1
	fi
    done
else
    echo "*** Using $MGMTLAN as the Management Network"
fi

echo "*** Moving Interfaces into OpenVSwitch Bridges"

$DIRNAME/setup-ovs.sh 1> $OURDIR/setup-ovs.log 2>&1

echo "*** Building an Openstack!"

ssh -o StrictHostKeyChecking=no ${CONTROLLER} "sh -c $DIRNAME/setup-controller.sh 1> $OURDIR/setup-controller.log 2>&1 </dev/null &"

exit 0
