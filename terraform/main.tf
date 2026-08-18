module "vpc" {
  source = "./modules/vpc"

  create_vpc                  = var.create_vpc
  name_prefix                 = local.name_prefix
  vpc_cidr                    = var.vpc_cidr
  availability_zones          = var.availability_zones
  private_subnet_cidrs        = var.private_subnet_cidrs
  existing_vpc_id             = var.existing_vpc_id
  existing_private_subnet_ids = local.existing_private_subnet_ids
}

module "security_groups" {
  source = "./modules/security-groups"

  vpc_id      = module.vpc.vpc_id
  name_prefix = local.name_prefix
}

module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix
}

module "s3" {
  source = "./modules/s3"

  bucket_name = "${local.name_prefix}-${data.aws_caller_identity.current.account_id}"
}

module "bastion" {
  source = "./modules/bastion"

  name_prefix           = local.name_prefix
  subnet_id             = module.vpc.private_subnet_ids[0]
  private_ip            = local.bastion_private_ip
  sg_id                 = module.security_groups.bastion_sg_id
  instance_profile_name = module.iam.instance_profile_names["bastion"]
  bastion_role_name     = module.iam.role_names["bastion"]
  instance_type         = var.bastion_instance_type
  ami_id                = var.bastion_ami_id
  cluster_name          = var.cluster_name
  base_domain           = var.base_domain
  upstream_dns          = local.upstream_dns
  ignition_bucket_name  = module.s3.bucket_id
  aws_region            = var.aws_region
}

module "control_plane" {
  count  = var.masters_enabled ? 1 : 0
  source = "./modules/control-plane"

  name_prefix           = local.name_prefix
  subnet_id             = module.vpc.private_subnet_ids[0]
  sg_id                 = module.security_groups.master_sg_id
  instance_profile_name = module.iam.instance_profile_names["master"]
  ami_id                = var.rhcos_ami_id
  instance_type         = var.master_instance_type
  root_volume_size      = var.master_root_volume_size
  master_count          = var.master_count
  bastion_private_ip    = module.bastion.private_ip
  mcs_ca_data_url       = var.mcs_ca_data_url
  tags                  = local.cluster_owned_tag
}

module "bootstrap" {
  count  = var.bootstrap_enabled ? 1 : 0
  source = "./modules/bootstrap"

  name_prefix           = local.name_prefix
  subnet_id             = module.vpc.private_subnet_ids[0]
  sg_id                 = module.security_groups.bootstrap_sg_id
  instance_profile_name = module.iam.instance_profile_names["bootstrap"]
  ami_id                = var.rhcos_ami_id
  bastion_private_ip    = module.bastion.private_ip
  tags                  = local.cluster_owned_tag
}

module "haproxy_config" {
  source = "./modules/haproxy-config"

  bastion_instance_id = module.bastion.instance_id
  bucket_name         = module.s3.bucket_id
  aws_region          = var.aws_region

  # api/mcs route to bootstrap+masters during bring-up, masters only once
  # bootstrap is torn down. Compact topology: masters are schedulable and
  # carry ingress traffic too (see docs/architecture.md), so ingress is
  # masters-only, never bootstrap. A client using dedicated workers instead
  # would split ingress_backends out to a workers module's own output.
  api_backends     = local.api_mcs_backends
  mcs_backends     = local.api_mcs_backends
  ingress_backends = local.master_backends
}
