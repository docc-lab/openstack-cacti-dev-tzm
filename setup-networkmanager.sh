#!/bin/sh

##
## Setup the OpenStack networkmanager node for Neutron.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-networkmanager-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

# Grab the neutron configuration we computed in setup-lib.sh
. $OURDIR/info.neutron

cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF

sysctl -p

maybe_install_packages neutron-plugin-ml2 neutron-plugin-openvswitch-agent \
    neutron-l3-agent neutron-dhcp-agent conntrack neutron-metering-agent

sed -i -e "s/^\\(.*connection.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/neutron/neutron.conf

# Just slap these in.
cat <<EOF >> /etc/neutron/neutron.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
core_plugin = ml2
service_plugins = router,metering
allow_overlapping_ips = True
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
notification_driver = messagingv2

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = neutron
admin_password = ${NEUTRON_PASS}
EOF

fwdriver="neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver"
if [ ${DISABLE_SECURITY_GROUPS} -eq 1 ]; then
    fwdriver="neutron.agent.firewall.NoopFirewallDriver"
fi

# Just slap these in.
cat <<EOF >> /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
type_drivers = ${network_types}
tenant_network_types = ${network_types}
mechanism_drivers = openvswitch

[ml2_type_flat]
flat_networks = ${flat_networks}

[ml2_type_gre]
tunnel_id_ranges = 1:1000

[ml2_type_vlan]
${network_vlan_ranges}

[ml2_type_vxlan]
vni_ranges = 3000:4000
#vxlan_group = 224.0.0.1

[securitygroup]
enable_security_group = True
enable_ipset = True
firewall_driver = $fwdriver

[ovs]
${gre_local_ip}
${enable_tunneling}
${bridge_mappings}

[agent]
${tunnel_types}
EOF

# Just slap these in.
cat <<EOF >> /etc/neutron/l3_agent.ini
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
use_namespaces = True
external_network_bridge = br-ex
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
EOF

# Just slap these in.
cat <<EOF >> /etc/neutron/dhcp_agent.ini
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
use_namespaces = True
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
EOF

# Uncomment if dhcp has trouble due to MTU
cat <<EOF >> /etc/neutron/dhcp_agent.ini
[DEFAULT]
dnsmasq_config_file = /etc/neutron/dnsmasq-neutron.conf
EOF
cat <<EOF >> /etc/neutron/dnsmasq-neutron.conf
dhcp-option-force=26,1454
log-queries
log-dhcp
no-resolv
server=8.8.8.8
EOF
pkill dnsmasq

sed -i -e "s/^.*auth_url.*=.*$/auth_url = http:\\/\\/$CONTROLLER:5000\\/v2.0/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*auth_region.*=.*$/auth_region = regionOne/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*admin_tenant_name.*=.*$/admin_tenant_name = service/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*admin_user.*=.*$/admin_user = neutron/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*admin_password.*=.*$/admin_password = ${NEUTRON_PASS}/" /etc/neutron/metadata_agent.ini

sed -i -e "s/^.*nova_metadata_ip.*=.*$/nova_metadata_ip = $CONTROLLER/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*metadata_proxy_shared_secret.*=.*$/metadata_proxy_shared_secret = $NEUTRON_METADATA_SECRET/" /etc/neutron/metadata_agent.ini
cat <<EOF >> /etc/neutron/metadata_agent.ini
[DEFAULT]
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
EOF

cat <<EOF >> /etc/neutron/metering_agent.ini
[DEFAULT]
debug = True
driver = neutron.services.metering.drivers.iptables.iptables_driver.IptablesMeteringDriver
measure_interval = 30
report_interval = 300
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
use_namespaces = True
EOF

#
# Ok, also put our FQDN into the hosts file so that local applications can
# resolve that pair even if the network happens to be down.  This happens,
# for instance, because of our anti-ARP spoofing "patch" to the openvswitch
# agent (the agent remove_all_flow()s on a switch periodically and inserts a
# default normal forwarding rule, plus anything it needs --- our patch adds some
# anti-ARP spoofing rules after remove_all but BEFORE the default normal rule
# gets added back (this is just the nature of the existing code in Juno and Kilo
# (the situation is easier to patch more nicely on the master branch, but we
# don't have Liberty yet)) --- and because it adds the rules via command line
# using sudo, and sudo tries to lookup the hostname --- this can cause a hang.)
# Argh, what a pain.  For the rest of this hack, see setup-ovs-node.sh, and
# setup-networkmanager.sh and setup-compute-network.sh where we patch the 
# neutron openvswitch agent.
#
echo "$MYIP    $NFQDN $PFQDN" >> /etc/hosts

#
# Patch the neutron openvswitch agent to try to stop inadvertent spoofing on
# the public emulab/cloudlab control net, sigh.
#
patch -d / -p0 < $DIRNAME/etc/neutron-${OSCODENAME}-openvswitch-remove-all-flows-except-system-flows.patch

service_restart openvswitch-switch
service_enable openvswitch-switch
service_restart neutron-plugin-openvswitch-agent
service_enable neutron-plugin-openvswitch-agent
service_restart neutron-l3-agent
service_enable neutron-l3-agent
service_restart neutron-dhcp-agent
service_enable neutron-dhcp-agent
service_restart neutron-metadata-agent
service_enable neutron-metadata-agent
service_restart neutron-metering-agent
service_enable neutron-metering-agent

touch $OURDIR/setup-networkmanager-done

exit 0
