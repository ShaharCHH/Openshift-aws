# Session Summary — OpenShift Agent-Based Install on AWS

## Project Overview

Deploying OpenShift 4.22 on AWS (il-central-1, Israel region) using the agent-based installer,
without Route 53. The environment is a restricted enterprise AWS account where the organization's
SCP (Service Control Policy) blocks multiple operations.

**User:** Shahar — OpenShift/AWS/Terraform user, prefers practical solutions over officially supported paths, budget-conscious.

**Platform:** WSL2 Ubuntu on Windows, Terraform v1.9.0.

---

## What Was Done

### 1. Initial Setup (INSTALL-GUIDE.md)

- Created a comprehensive install guide with beginner-friendly explanations
- Two-phase Terraform approach: Phase 1 creates infra + ENIs (for MAC addresses), Phase 2 boots instances with agent AMI
- Added explanations for every concept (VPC, ENI, AMI, ISO, MAC addresses, etc.)

### 2. Refactored for Existing VPC

**Problem:** SCP blocks `ec2:CreateVpc` and `ec2:AllocateAddress`.

**Solution:** Made all VPC resources conditional with `count = local.create_vpc ? 1 : 0`. Added variables:
- `existing_vpc_id`
- `existing_private_subnet_id`  
- `existing_public_subnet_id`

**Files changed:**
- `terraform/variables.tf` — added existing VPC variables
- `terraform/dev.tfvars` — set existing VPC/subnet IDs
- `terraform/main.tf` — conditional subnet selection
- `terraform/modules/vpc/main.tf` — all resources conditional, uses `data.aws_vpc.existing`
- `terraform/modules/vpc/variables.tf` — added existing VPC variables
- `terraform/modules/vpc/outputs.tf` — conditional outputs

**Existing VPC details:**
- VPC: `vpc-0c5eaad2eb2976b41` (CIDR: `10.3.64.0/22`)
- Private subnet: `subnet-01996bb83a6db398c`
- Public subnet (with IGW): `subnet-04c18afcc7956af21`

### 3. Replaced NLB with HAProxy on Bastion

**Problem:** SCP blocks `elasticloadbalancing:CreateLoadBalancer`.

**Solution:** Renamed the CoreDNS instance to "bastion" (serves 3 roles: DNS, load balancer, SSM entry point). Added HAProxy as a TCP load balancer running alongside CoreDNS as Docker containers.

**Module rename:** `modules/coredns` → `modules/bastion` with `moved` blocks for state migration.

**Files changed/created:**
- `terraform/modules/bastion/main.tf` — renamed all resources from `coredns` → `bastion`, added HAProxy template, added `moved` blocks
- `terraform/modules/bastion/variables.tf` — `coredns_ip` → `bastion_ip`, `coredns_sg_id` → `bastion_sg_id`, `public_subnet_id` → `subnet_id`
- `terraform/modules/bastion/outputs.tf` — references `aws_instance.bastion`, removed `public_ip` output
- `terraform/modules/security-groups/main.tf` — renamed SG `coredns` → `bastion`, added HAProxy ports (6443, 22623, 443, 80), added `moved` blocks
- `terraform/modules/security-groups/outputs.tf` — `coredns_sg_id` → `bastion_sg_id`
- `terraform/modules/compute/main.tf` — removed all 4 `aws_lb_target_group_attachment` resources
- `terraform/modules/compute/variables.tf` — removed 4 target group ARN variables
- `terraform/main.tf` — removed `module "nlb"`, renamed to `module "bastion"`, added `moved` block
- `terraform/outputs.tf` — renamed outputs, removed NLB output
- `terraform/variables.tf` — `coredns_ip` → `bastion_ip`
- `terraform/dev.tfvars` — `coredns_ip` → `bastion_ip`
- `terraform/templates/coredns-zonefile.tpl` — all DNS records point to `${bastion_ip}`, removed master_ips loop
- `terraform/templates/haproxy.cfg.tpl` — **NEW** TCP LB config (4 frontends: 6443, 22623, 443, 80)
- `terraform/templates/bastion-userdata.sh.tpl` — **NEW** (replaced `coredns-userdata.sh.tpl`)
- `terraform/modules/nlb/` — **DELETED** entire directory
- `terraform/templates/coredns-userdata.sh.tpl` — **DELETED** (replaced by bastion-userdata.sh.tpl)
- `scripts/ssm-tunnel.sh` — **NEW** SSM port forwarding script
- `INSTALL-GUIDE.md` — fully rewritten for bastion/HAProxy/SSM flow
- `SCP-BLOCKERS.md` — **NEW** documents all SCP blockers

### 4. Fixed Podman → Docker

**Problem:** `podman` is not available in Amazon Linux 2023 default repos.

**Solution:** Switched to `docker` (available via `dnf install -y docker`).

**Problem:** HAProxy container couldn't bind ports 80/443 (Permission denied).

**Solution:** Added `--user root` to the HAProxy `docker run` command. The HAProxy Alpine image drops to non-root internally.

**Final bastion-userdata.sh.tpl uses:**
```bash
dnf install -y docker bind-utils
systemctl enable --now docker
docker run -d --name coredns --network host --restart always ...
docker run -d --name haproxy --network host --restart always --user root ...
```

### 5. Fixed Agent ISO Generation

**Problem:** `nmstatectl` not available on WSL2 Ubuntu, and pip install has broken dependency chain (needs `nispor` which has no pip wheel).

**Solution:** Removed the `networkConfig` section from agent-config.yaml in `scripts/generate-agent-iso.sh`. AWS ENIs already have fixed IPs via DHCP — the nmstate network config was unnecessary. Only MAC-to-hostname mapping is needed.

Also fixed: `COREDNS_IP` hardcoded default → now reads `bastion_private_ip` from Terraform output.

**File changed:** `scripts/generate-agent-iso.sh`

### 6. ISO-to-AMI Import — BLOCKED

**Problem:** SCP blocks `ec2:CopySnapshot` for the vmimport role. The `./scripts/import-iso-to-ami.sh` fails at 71% when the vmimport service tries to copy the snapshot.

**This is the current blocker.** Two options identified:
1. **Cross-account import** — run import in a sandbox account, share AMI to `342831714456`
2. **Switch to UPI** — use pre-built RHCOS AMI (`ami-0e9a0f9e1a4c49b92`) with ignition configs instead of agent ISO

---

## Current State of Infrastructure

**Terraform applied successfully.** Bastion is running with CoreDNS + HAProxy containers.

```
Bastion instance: i-0e42d40444af4de59
Bastion IP: 10.3.65.10
Master ENI IPs: 10.3.65.214, 10.3.65.51, 10.3.65.16
Master MACs: 06:3d:46:78:ca:03, 06:3b:ca:33:5e:7d, 06:a7:1c:3f:7f:1b
S3 bucket: dev-ocp-20260811112514368500000003
```

**Master instances are NOT created yet** — waiting for a valid AMI ID.

**Agent ISO was generated successfully** at `~/ocp-install/dev/agent.x86_64.iso`.

---

## All SCP Blockers

| # | Blocked Operation | Workaround | Status |
|---|---|---|---|
| 1 | Route 53 | CoreDNS on bastion | Resolved |
| 2 | `ec2:CreateVpc` | Existing spoke VPC | Resolved |
| 3 | `ec2:AllocateAddress` | Private subnet + SSM | Resolved |
| 4 | `elasticloadbalancing:CreateLoadBalancer` | HAProxy on bastion | Resolved |
| 5 | `ec2:CopySnapshot` (vmimport) | **Pending** — cross-account or UPI | **Blocked** |

---

## Key File Paths

```
terraform/
├── main.tf                          # Module orchestration, moved blocks
├── variables.tf                     # Root variables (bastion_ip, existing_vpc_*)
├── outputs.tf                       # bastion_instance_id, cluster_info
├── dev.tfvars                       # Environment values
├── modules/
│   ├── bastion/                     # CoreDNS + HAProxy instance (renamed from coredns)
│   │   ├── main.tf                  # IAM, templates, instance, moved blocks
│   │   ├── variables.tf             # bastion_ip, master_ips, subnet_id
│   │   └── outputs.tf               # instance_id, private_ip
│   ├── compute/                     # ENIs + conditional master instances
│   ├── vpc/                         # Conditional VPC (supports existing)
│   ├── security-groups/             # Master + bastion SGs
│   ├── iam/                         # Master IAM role + SSM
│   └── s3/                          # ISO upload bucket
├── templates/
│   ├── bastion-userdata.sh.tpl      # Docker: CoreDNS + HAProxy
│   ├── haproxy.cfg.tpl              # TCP LB config
│   ├── coredns-corefile.tpl         # CoreDNS Corefile
│   └── coredns-zonefile.tpl         # DNS zone (all → bastion IP)
scripts/
├── generate-agent-iso.sh            # Generates agent ISO from Terraform outputs
├── import-iso-to-ami.sh             # ISO → AMI (currently blocked by SCP)
├── ssm-tunnel.sh                    # SSM port forwarding to bastion
├── hibernate.sh                     # Stop instances
└── wake.sh                          # Start instances
INSTALL-GUIDE.md                     # Full installation guide
SCP-BLOCKERS.md                      # Documented SCP blockers
```

---

## Next Steps

1. **Resolve blocker #5** — get the agent ISO imported as an AMI (cross-account or switch to UPI)
2. **Boot masters** — `terraform apply -var-file=dev.tfvars -var="agent_ami_id=ami-xxx"`
3. **Wait for install** — `openshift-install agent wait-for install-complete --dir ~/ocp-install/dev`
4. **Access cluster** — `./scripts/ssm-tunnel.sh` + `/etc/hosts` pointing to `127.0.0.1`
5. **Install SSM plugin** on local machine — `sudo dpkg -i session-manager-plugin.deb`
