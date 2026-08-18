output "vpc_id" {
  value = module.vpc.vpc_id
}

output "bastion_instance_id" {
  value = module.bastion.instance_id
}

output "bastion_private_ip" {
  value = module.bastion.private_ip
}

output "cluster_domain" {
  value = local.cluster_domain
}

output "ignition_bucket_name" {
  value = module.s3.bucket_id
}

output "master_instance_ids" {
  value = var.masters_enabled ? module.control_plane[0].instance_ids : []
}

output "master_private_ips" {
  value = var.masters_enabled ? module.control_plane[0].private_ips : []
}

output "bootstrap_instance_id" {
  value = var.bootstrap_enabled ? module.bootstrap[0].instance_id : null
}

# Consumed by scripts/ignition/render-install-config.sh (Phase 2, not yet
# built) so install-config.yaml never needs network details re-typed by hand.
output "install_config_inputs" {
  value = {
    aws_region         = var.aws_region
    vpc_id             = module.vpc.vpc_id
    machine_cidr       = module.vpc.vpc_cidr
    private_subnet_ids = module.vpc.private_subnet_ids
    cluster_name       = var.cluster_name
    base_domain        = var.base_domain
  }
}
