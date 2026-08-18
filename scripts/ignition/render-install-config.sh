#!/usr/bin/env bash
# Builds install-config.yaml from `terraform output -json install_config_inputs`
# plus a pull secret and SSH public key file -- no network details are ever
# re-typed by hand.
#
# Compact topology: compute.replicas = 0. The installer leaves masters
# schedulable by default in that case -- unlike a standard topology with
# dedicated workers, there is no manifest patch to apply here. See
# docs/architecture.md.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=../lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: render-install-config.sh -a <account-alias> --pull-secret <path> --ssh-key <path>"
  exit 1
}

account_alias=""
pull_secret_path=""
ssh_key_path=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --pull-secret)
      pull_secret_path="$2"
      shift 2
      ;;
    --ssh-key)
      ssh_key_path="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] && [ -n "$pull_secret_path" ] && [ -n "$ssh_key_path" ] || usage
[ -f "$pull_secret_path" ] || {
  echo "ERROR: pull secret not found at $pull_secret_path" >&2
  exit 1
}
[ -f "$ssh_key_path" ] || {
  echo "ERROR: SSH public key not found at $ssh_key_path" >&2
  exit 1
}

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found." >&2
  exit 1
}

master_instance_type=$(read_tfvar master_instance_type "$tfvars")
master_instance_type="${master_instance_type:-m5.xlarge}"
master_count=$(read_tfvar master_count "$tfvars")
master_count="${master_count:-3}"

echo "Reading install_config_inputs from terraform output..." >&2
inputs=$(cd "$repo_root/terraform" && terraform output -json install_config_inputs)

aws_region=$(echo "$inputs" | jq -r '.aws_region')
cluster_name=$(echo "$inputs" | jq -r '.cluster_name')
base_domain=$(echo "$inputs" | jq -r '.base_domain')
machine_cidr=$(echo "$inputs" | jq -r '.machine_cidr')

out_dir="$repo_root/.ignition/${account_alias}"
mkdir -p "$out_dir"
out_file="$out_dir/install-config.yaml"

pull_secret_json=$(jq -c . "$pull_secret_path")
ssh_key=$(cat "$ssh_key_path")

{
  echo "apiVersion: v1"
  echo "baseDomain: ${base_domain}"
  echo "metadata:"
  echo "  name: ${cluster_name}"
  echo "platform:"
  echo "  aws:"
  echo "    region: ${aws_region}"
  echo "    vpc:"
  echo "      subnets:"
  # Explicit subnet roles, not the deprecated flat `subnets: [id, ...]` list --
  # this VPC has other, unrelated subnets in it (other teams' infrastructure),
  # and the installer refuses to guess which are ours without either roles
  # here or a kubernetes.io/cluster/<id> tag on every other subnet (which
  # would mean tagging infrastructure we don't own). ControlPlaneExternalLB
  # is deliberately omitted -- not required when publish: Internal. These
  # roles are bookkeeping for `create ignition-configs`, not real AWS calls:
  # in UPI, openshift-install never provisions a load balancer itself (that's
  # HAProxy on the bastion, per docs/architecture.md), regardless of what's
  # declared here.
  echo "$inputs" | jq -r '.private_subnet_ids[] |
    "      - id: " + . + "\n        roles:\n        - type: ClusterNode\n        - type: BootstrapNode\n        - type: IngressControllerLB\n        - type: ControlPlaneInternalLB"'
  echo "controlPlane:"
  echo "  name: master"
  echo "  replicas: ${master_count}"
  echo "  platform:"
  echo "    aws:"
  echo "      type: ${master_instance_type}"
  echo "compute:"
  echo "- name: worker"
  echo "  replicas: 0"
  echo "networking:"
  echo "  networkType: OVNKubernetes"
  echo "  clusterNetwork:"
  echo "  - cidr: 10.128.0.0/14"
  echo "    hostPrefix: 23"
  echo "  serviceNetwork:"
  echo "  - 172.30.0.0/16"
  echo "  machineNetwork:"
  echo "  - cidr: ${machine_cidr}"
  echo "publish: Internal"
  # Mint/Passthrough modes need to embed long-lived credentials into the
  # cluster for its own operators to use -- SSO's temporary session can't
  # satisfy that (and wouldn't want to; it'd expire and break things), and
  # this account almost certainly can't do IAM-user minting either. Manual
  # is the right choice independent of the credential-provider issue: no
  # AWS credentials get embedded in the cluster at all.
  echo "credentialsMode: Manual"
  echo "pullSecret: '${pull_secret_json}'"
  echo "sshKey: '${ssh_key}'"
} >"$out_file"

echo "Wrote $out_file" >&2
echo "$out_file"
