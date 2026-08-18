locals {
  name_prefix    = "${var.cluster_name}-${var.account_alias}"
  cluster_domain = "${var.cluster_name}.${var.base_domain}"

  # See variables.tf's cluster_infra_id for why this exists. Empty when
  # unset so master/bootstrap can still be planned (e.g. tainting/replacing)
  # without requiring it.
  cluster_owned_tag = var.cluster_infra_id != null ? {
    "kubernetes.io/cluster/${var.cluster_infra_id}" = "owned"
  } : {}

  existing_private_subnet_ids = var.existing_private_subnet_id != null ? [var.existing_private_subnet_id] : []

  # The VPC's own built-in Route 53 Resolver (base+2) -- what CoreDNS
  # forwards non-cluster queries to.
  upstream_dns = cidrhost(module.vpc.vpc_cidr, 2)

  # Pinned rather than discovered at boot -- see modules/bastion's
  # `private_ip` variable for why. Offset 250 (near the top of the range,
  # not 10) deliberately -- this subnet is shared with other real,
  # dynamically-provisioned workloads (confirmed via a real collision at
  # offset 10 during testing), so low offsets aren't safe to assume free.
  # This is still a static guess, not a reservation -- a genuinely safe
  # fix would carve out a dedicated subnet or IPAM exclusion for a client
  # with a busy shared subnet like this one.
  bastion_private_ip = cidrhost(module.vpc.private_subnet_cidrs[0], 250)

  # The false branch deliberately never references module.control_plane[0]
  # (Terraform lazily evaluates only the taken ternary branch), so this is
  # safe even when masters_enabled = false and the module has count = 0.
  master_backends = var.masters_enabled ? [
    for idx, ip in module.control_plane[0].private_ips : { name = "master-${idx}", ip = ip }
  ] : []

  bootstrap_backend = var.bootstrap_enabled ? [
    { name = "bootstrap", ip = module.bootstrap[0].private_ip }
  ] : []

  # API/MCS route to bootstrap+masters during bring-up, masters only once
  # bootstrap is torn down (bootstrap_enabled flips to false). Ingress never
  # includes bootstrap -- it's masters-only even during bring-up, since
  # compact masters (not bootstrap) are what eventually serve real traffic.
  api_mcs_backends = concat(local.bootstrap_backend, local.master_backends)
}
