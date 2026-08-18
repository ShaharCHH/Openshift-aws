# NetworkManager keyfile for cluster nodes' real root filesystem.
#
# WHY THIS EXISTS: the AMI carries `ip=dhcp nameserver=<bastion>` as kernel
# arguments (scripts/ami-build/build-custom-ami.sh), because Ignition has to
# resolve api-int inside the initramfs, before a root filesystem exists. Those
# arguments do their job -- but on RHEL 9 they also change NetworkManager's
# behaviour on the real root: the initrd hands over a connection on first boot,
# and with no persistent profile on disk, every LATER boot comes up with the
# interface unconfigured.
#
# Confirmed the expensive way. All three masters rebooted together when the MCO
# applied its rendered config, and came back with no address at all:
#
#   ens5:
#   Ignition: ran on 2026/08/18 09:17:45 UTC (at least 2 boots ago)
#
# All three kubelets stopped posting within two seconds of each other. AWS still
# held every private IP on an attached, in-use ENI, so the VPC would happily have
# handed out the leases -- the failure was entirely inside the guest. Since the
# MCO reboots nodes as routine maintenance, a cluster without this file cannot
# survive its own first config rollout.
#
# Delivered through the wrapper ignition rather than baked into the AMI: Ignition's
# storage stage runs after config resolution but still in the initramfs, writing to
# /sysroot, so this lands before the first real-root boot. See docs/architecture.md.

[connection]
id=default-dhcp
type=ethernet
autoconnect=true
# Last-resort profile: anything more specific NetworkManager finds wins over it.
autoconnect-priority=-999

[ipv4]
method=auto
# The bastion's CoreDNS is the only resolver that knows the cluster's names, and
# it forwards everything else upstream. dns-priority beats NM's default of 100,
# so this is consulted first while DHCP-provided resolvers remain as fallback.
dns=${bastion_private_ip};
dns-priority=10

[ipv6]
# Left enabled rather than disabled -- OVN-Kubernetes uses IPv6 on some internal
# paths, and may-fail keeps a missing IPv6 lease from holding up the connection.
method=auto
may-fail=true
