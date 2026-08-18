# Four security groups: bastion (CoreDNS+HAProxy), master, worker, bootstrap.
#
# Cross-references between these groups are done as standalone
# aws_vpc_security_group_ingress_rule resources rather than inline
# ingress {} blocks on aws_security_group — two SGs whose inline rules
# reference each other's id form a real dependency cycle at apply time;
# standalone rule resources don't, since the (ruleless) groups exist first.

resource "aws_security_group" "bastion" {
  name_prefix = "${var.name_prefix}-bastion-"
  description = "Bastion: CoreDNS (DNS) + HAProxy (API/MCS/ingress LB)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-bastion" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "master" {
  name_prefix = "${var.name_prefix}-master-"
  description = "OpenShift control plane"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-master" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "worker" {
  name_prefix = "${var.name_prefix}-worker-"
  description = "OpenShift compute"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-worker" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "bootstrap" {
  name_prefix = "${var.name_prefix}-bootstrap-"
  description = "OpenShift temporary bootstrap node"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-bootstrap" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---- egress: every group can reach anywhere (S3 ignition fetch, SSM, etc.) ----

resource "aws_vpc_security_group_egress_rule" "all_egress" {
  for_each = {
    bastion   = aws_security_group.bastion.id
    master    = aws_security_group.master.id
    worker    = aws_security_group.worker.id
    bootstrap = aws_security_group.bootstrap.id
  }

  security_group_id = each.value
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "allow all outbound"
}

# ---- bastion ingress: master/worker/bootstrap talk to CoreDNS(53), HAProxy(6443/22623/443/80),
# and the bastion's own ignition HTTP server (8080 -- see docs/architecture.md; deliberately not
# 80/443, which HAProxy already owns for cluster ingress traffic) ----

locals {
  bastion_ports = {
    dns_tcp  = { port = 53, proto = "tcp" }
    dns_udp  = { port = 53, proto = "udp" }
    api      = { port = 6443, proto = "tcp" }
    mcs      = { port = 22623, proto = "tcp" }
    https    = { port = 443, proto = "tcp" }
    http     = { port = 80, proto = "tcp" }
    ignition = { port = 8080, proto = "tcp" }
  }
  bastion_sources = {
    master    = aws_security_group.master.id
    worker    = aws_security_group.worker.id
    bootstrap = aws_security_group.bootstrap.id
  }
  bastion_ingress = {
    for pair in setproduct(keys(local.bastion_ports), keys(local.bastion_sources)) :
    "${pair[0]}-${pair[1]}" => {
      port   = local.bastion_ports[pair[0]].port
      proto  = local.bastion_ports[pair[0]].proto
      source = local.bastion_sources[pair[1]]
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "bastion" {
  for_each = local.bastion_ingress

  security_group_id            = aws_security_group.bastion.id
  referenced_security_group_id = each.value.source
  ip_protocol                  = each.value.proto
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "bastion from ${each.key}"
}

# ---- HAProxy on the bastion reaching real backends ----

# http/https are here, not only on the worker SG below, because this is a
# compact topology: masters are schedulable and run the ingress routers
# themselves, so HAProxy's ingress_backends point at master IPs (see
# main.tf's haproxy_config block). Those routers bind the node's own :80 and
# :443 because the default IngressController is pinned to HostNetwork rather
# than a LoadBalancer Service -- ELB creation being SCP-blocked is the whole
# reason HAProxy exists here. Without these two rules HAProxy is pointed at
# ports it cannot reach, and ingress fails with no error on the router side
# at all.
resource "aws_vpc_security_group_ingress_rule" "master_from_bastion" {
  for_each = { api = 6443, mcs = 22623, http = 80, https = 443 }

  security_group_id            = aws_security_group.master.id
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "haproxy to master ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "bootstrap_from_bastion" {
  for_each = { api = 6443, mcs = 22623 }

  security_group_id            = aws_security_group.bootstrap.id
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "haproxy to bootstrap ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "worker_from_bastion" {
  for_each = { http = 80, https = 443 }

  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "haproxy to worker ingress ${each.key}"
}

# ---- the kubernetes Service ClusterIP (172.30.0.1:443) ----
#
# Every in-cluster client reaches the API through this Service, and OVN
# DNATs it to whichever node currently backs it -- bootstrap during
# bring-up, the masters once bootstrap is torn down. That DNAT'd packet
# leaves the node directly, NOT through the bastion, so the bastion-sourced
# rules above never cover it.
#
# Missing these two stalled an entire cluster for real: every operator pod
# got `dial tcp 172.30.0.1:443: i/o timeout` (a silent SG drop, not a
# refused connection), so service-ca-operator never issued the *-serving-cert
# secrets, ~15 pods sat in ContainerCreating on FailedMount, MCO never ran,
# and the masters never received their etcd/kube-apiserver static pod
# manifests. Nothing in the earlier bring-up exercises this path, because
# every other route to the API (HAProxy, api-int:22623) goes via the bastion.

resource "aws_vpc_security_group_ingress_rule" "bootstrap_api_from_master" {
  security_group_id            = aws_security_group.bootstrap.id
  referenced_security_group_id = aws_security_group.master.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "kubernetes Service ClusterIP to bootstrap API during bring-up"
}

resource "aws_vpc_security_group_ingress_rule" "master_api_from_master" {
  security_group_id            = aws_security_group.master.id
  referenced_security_group_id = aws_security_group.master.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "kubernetes Service ClusterIP to master API once bootstrap is gone"
}

# ---- intra-cluster: etcd (masters only) + kubelet (all nodes) ----

resource "aws_vpc_security_group_ingress_rule" "etcd" {
  security_group_id            = aws_security_group.master.id
  referenced_security_group_id = aws_security_group.master.id
  ip_protocol                  = "tcp"
  from_port                    = 2379
  to_port                      = 2380
  description                  = "etcd peer + client"
}

# etcd's first member runs on the BOOTSTRAP node, not a master: masters join
# that cluster as peers and only take it over once bootstrap is torn down.
# So etcd traffic has to flow both ways between bootstrap and the masters,
# and master-to-master alone (above) is not enough during bring-up.
#
# Confirmed for real, and it is silent in a way worth knowing: the etcd
# static pod on a master starts with an EMPTY ETCDCTL_ENDPOINTS (the
# operator could not populate it, having never reached the bootstrap etcd),
# falls back to 127.0.0.1:2379 where nothing is listening, and dies with
# "failed to create etcd client: context deadline exceeded". Nothing in that
# message points at bootstrap or at a firewall -- the only way to see it is
# to test the path directly:
#   master -> bootstrap:2379  BLOCKED
#   master -> bootstrap:2380  BLOCKED
# With etcd down there is no kube-apiserver, and every other operator's
# failure is downstream noise.
resource "aws_vpc_security_group_ingress_rule" "etcd_bootstrap" {
  for_each = {
    bootstrap_from_master = { sg = aws_security_group.bootstrap.id, src = aws_security_group.master.id }
    master_from_bootstrap = { sg = aws_security_group.master.id, src = aws_security_group.bootstrap.id }
  }

  security_group_id            = each.value.sg
  referenced_security_group_id = each.value.src
  ip_protocol                  = "tcp"
  from_port                    = 2379
  to_port                      = 2380
  description                  = "etcd peer + client (${each.key})"
}

resource "aws_vpc_security_group_ingress_rule" "kubelet" {
  for_each = {
    master_from_master    = { sg = aws_security_group.master.id, src = aws_security_group.master.id }
    master_from_worker    = { sg = aws_security_group.master.id, src = aws_security_group.worker.id }
    master_from_bootstrap = { sg = aws_security_group.master.id, src = aws_security_group.bootstrap.id }
    worker_from_master    = { sg = aws_security_group.worker.id, src = aws_security_group.master.id }
    worker_from_worker    = { sg = aws_security_group.worker.id, src = aws_security_group.worker.id }
  }

  security_group_id            = each.value.sg
  referenced_security_group_id = each.value.src
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet API (${each.key})"
}

# ---- pod network: OVN-Kubernetes node-to-node ----
#
# OVN encapsulates every pod-to-pod packet that crosses a node boundary in
# Geneve (UDP 6081). Without that one rule, pods on the same node talk fine and
# pods on different nodes cannot reach each other at all -- and because the
# cluster is *partly* functional, the symptoms surface far from the cause:
# openshift-apiserver's aggregated APIs return 503, so route.openshift.io stops
# answering, so the ingress routers fail their has-synced probe and restart in a
# loop, so authentication and console go Degraded complaining about routes. None
# of those messages mention the network.
#
# Confirmed directly rather than inferred, from a node with a Ready DNS pod on
# every node:
#   SAME node  -> pod 10.129.0.25:5353  OPEN
#   OTHER node -> pod 10.130.0.50:5353  BLOCKED
#   OTHER node -> pod 10.128.0.21:5353  BLOCKED
#
# The other two ranges come from Red Hat's documented UPI firewall requirements
# and are added here rather than waiting for each to announce itself the way
# Geneve did: 9000-9999 for host-level services (node-exporter and friends, which
# Prometheus scrapes across nodes) and 30000-32767 for NodePort. Every one of
# these is scoped to this deployment's own security groups -- nothing is opened
# to a CIDR.
locals {
  pod_network_ports = {
    geneve       = { proto = "udp", from = 6081, to = 6081 }
    host_svc_tcp = { proto = "tcp", from = 9000, to = 9999 }
    host_svc_udp = { proto = "udp", from = 9000, to = 9999 }
    nodeport_tcp = { proto = "tcp", from = 30000, to = 32767 }
    nodeport_udp = { proto = "udp", from = 30000, to = 32767 }
  }

  # Bootstrap is included: it joins the pod network too while it is alive.
  pod_network_pairs = {
    master_from_master    = { sg = aws_security_group.master.id, src = aws_security_group.master.id }
    master_from_worker    = { sg = aws_security_group.master.id, src = aws_security_group.worker.id }
    master_from_bootstrap = { sg = aws_security_group.master.id, src = aws_security_group.bootstrap.id }
    worker_from_master    = { sg = aws_security_group.worker.id, src = aws_security_group.master.id }
    worker_from_worker    = { sg = aws_security_group.worker.id, src = aws_security_group.worker.id }
    bootstrap_from_master = { sg = aws_security_group.bootstrap.id, src = aws_security_group.master.id }
  }

  pod_network_rules = {
    for pair in setproduct(keys(local.pod_network_ports), keys(local.pod_network_pairs)) :
    "${pair[0]}-${pair[1]}" => {
      proto = local.pod_network_ports[pair[0]].proto
      from  = local.pod_network_ports[pair[0]].from
      to    = local.pod_network_ports[pair[0]].to
      sg    = local.pod_network_pairs[pair[1]].sg
      src   = local.pod_network_pairs[pair[1]].src
      label = pair[0]
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "pod_network" {
  for_each = local.pod_network_rules

  security_group_id            = each.value.sg
  referenced_security_group_id = each.value.src
  ip_protocol                  = each.value.proto
  from_port                    = each.value.from
  to_port                      = each.value.to
  description                  = "pod network ${each.value.label} (${each.key})"
}
