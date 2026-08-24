#!/usr/bin/env bash
# Tears the cluster down. Same lifecycle family as hibernate.sh/wake.sh, but
# irreversible where those are a pause -- so this asks for explicit
# confirmation before touching anything, unlike the rest of this repo's
# scripts.
#
# Two modes, from docs/runbook.md's Day-2 operations:
#   default        -- full `terraform destroy`
#   --keep-bastion -- `terraform apply -var="masters_enabled=false"
#                      -var="bootstrap_enabled=false"`, useful between
#                      rebuild attempts without losing the bastion/DNS/S3
#
# Either way, the custom RHCOS AMI and its snapshot are NOT
# Terraform-managed (built by scripts/ami-build/build-custom-ami.sh outside
# any state Terraform tracks) and survive both. --deregister-ami handles
# that explicitly rather than leaving it as a "by hand" runbook footnote.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: teardown.sh -a <account-alias> [--keep-bastion] [--deregister-ami]" >&2
  exit 1
}

account_alias=""
keep_bastion=false
deregister_ami=false
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --keep-bastion)
      keep_bastion=true
      shift
      ;;
    --deregister-ami)
      deregister_ami=true
      shift
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

if [ "$keep_bastion" = true ]; then
  echo "This will tear down masters/bootstrap for account-alias=${account_alias}, keeping the bastion."
else
  echo "This will FULLY DESTROY the account-alias=${account_alias} deployment (terraform destroy)."
fi
read -r -p "Type the account alias to confirm: " confirm
if [ "$confirm" != "$account_alias" ]; then
  echo "Confirmation did not match. Aborting -- nothing was touched." >&2
  exit 1
fi

cd "$repo_root/terraform"

if [ "$keep_bastion" = true ]; then
  terraform apply -var-file="$tfvars" -var="masters_enabled=false" -var="bootstrap_enabled=false"
else
  terraform destroy -var-file="$tfvars"
fi

if [ "$deregister_ami" = true ]; then
  echo >&2
  echo "Deregistering custom RHCOS AMI(s) for account-alias=${account_alias}..." >&2
  images=$(aws ec2 describe-images --region "$region" --owners self \
    --filters "Name=name,Values=rhcos-*-custom-${account_alias}" \
    --query 'Images[].[ImageId,BlockDeviceMappings[0].Ebs.SnapshotId]' --output text)
  if [ -z "$images" ]; then
    echo "None found." >&2
  else
    echo "$images" | while read -r image_id snapshot_id; do
      [ -n "$image_id" ] || continue
      echo "  deregistering $image_id" >&2
      aws ec2 deregister-image --region "$region" --image-id "$image_id"
      if [ -n "$snapshot_id" ] && [ "$snapshot_id" != "None" ]; then
        echo "  deleting snapshot $snapshot_id" >&2
        aws ec2 delete-snapshot --region "$region" --snapshot-id "$snapshot_id" 2>/dev/null \
          || echo "    (delete failed, check manually)" >&2
      fi
    done
  fi
fi

echo "Done."
