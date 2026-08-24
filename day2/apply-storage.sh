#!/usr/bin/env bash
# Applies manifests/storage/nfs-provisioner.yaml -- the EFS-backed dynamic
# StorageClass (efs-nfs) this cluster uses in place of a CSI driver. See
# docs/architecture.md's storage section for why: no pod here can hold an
# AWS credential, so no CSI driver can ever authenticate, and EFS spoken as
# plain NFS is the only path that doesn't need one.
#
# Replaces the manual step in docs/runbook.md's Phase 8: the manifest ships
# with a literal EFS_DNS_NAME placeholder (the filesystem doesn't exist until
# Terraform has run), substituted here from the same tag-based EFS discovery
# day2/prepare-efs-root.sh uses.
#
# Runs prepare-efs-root.sh first, unconditionally -- the provisioner is
# useless without the export root existing, and running it here means this
# is the one command that reliably brings storage up end to end.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../scripts/lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: apply-storage.sh -a <account-alias>" >&2
  exit 1
}

account_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] || usage

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found." >&2
  exit 1
}
region=$(read_tfvar aws_region "$tfvars")
[ -n "$region" ] || {
  echo "ERROR: aws_region not set in $tfvars" >&2
  exit 1
}

kubeconfig="$repo_root/.ignition/${account_alias}/auth/kubeconfig"
[ -f "$kubeconfig" ] || {
  echo "ERROR: $kubeconfig not found." >&2
  echo "Run scripts/ignition/generate-ignition.sh -a $account_alias first." >&2
  exit 1
}
command -v oc >/dev/null 2>&1 || {
  echo "ERROR: oc not found on PATH." >&2
  exit 1
}

echo "=== 1/2: preparing the EFS export root ===" >&2
"$script_dir/prepare-efs-root.sh" -a "$account_alias"

echo >&2
echo "=== 2/2: applying the NFS provisioner + efs-nfs StorageClass ===" >&2

# Same tag-based EFS discovery as prepare-efs-root.sh -- see that script for
# why this works without terraform state.
fs_arn=$(aws resourcegroupstaggingapi get-resources --region "$region" \
  --tag-filters "Key=AccountAlias,Values=${account_alias}" "Key=Project,Values=openshift-upi" \
  --resource-type-filters "elasticfilesystem:file-system" \
  --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || echo "None")
[ -n "$fs_arn" ] && [ "$fs_arn" != "None" ] || {
  echo "ERROR: no EFS filesystem found for account-alias=${account_alias}." >&2
  exit 1
}
efs_dns="${fs_arn##*/}.efs.${region}.amazonaws.com"
echo "EFS DNS name: $efs_dns" >&2

sed "s/EFS_DNS_NAME/${efs_dns}/g" "$repo_root/manifests/storage/nfs-provisioner.yaml" | \
  oc --kubeconfig "$kubeconfig" apply -f - || {
  echo "ERROR: oc apply failed. Is a tunnel open (scripts/tunnel.sh -a $account_alias)," >&2
  echo "or are you running this from the bastion where oc reaches the API directly?" >&2
  exit 1
}

echo >&2
echo "Waiting for the nfs-provisioner Deployment to become available..." >&2
oc --kubeconfig "$kubeconfig" -n nfs-provisioner rollout status deployment/nfs-provisioner --timeout=120s

echo >&2
oc --kubeconfig "$kubeconfig" get sc
echo >&2
echo "Done. Verify provisioning actually works with day2/verify-storage.sh -a $account_alias." >&2
