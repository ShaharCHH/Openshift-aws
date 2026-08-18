#!/usr/bin/env bash
# Starts every stopped EC2 instance belonging to this deployment. Starts the
# bastion and waits for its SSM agent to come back online before returning
# -- CoreDNS/HAProxy need to be up for masters to cleanly rejoin cluster
# networking after a restart, and it's the SSM entry point for everything
# else anyway.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: wake.sh -a <account-alias>"
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

ids=$(aws ec2 describe-instances --region "$region" \
  --filters "Name=tag:AccountAlias,Values=${account_alias}" \
            "Name=tag:Project,Values=openshift-upi" \
            "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -z "$ids" ]; then
  echo "No stopped instances found for account-alias=${account_alias}. Nothing to do."
  exit 0
fi

# shellcheck disable=SC2086
echo "Starting: $ids"
# shellcheck disable=SC2086
aws ec2 start-instances --region "$region" --instance-ids $ids >/dev/null
# shellcheck disable=SC2086
aws ec2 wait instance-running --region "$region" --instance-ids $ids

bastion_id=$(aws ec2 describe-instances --region "$region" \
  --filters "Name=tag:AccountAlias,Values=${account_alias}" "Name=tag:Name,Values=*-bastion" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -n "$bastion_id" ]; then
  echo "Waiting for bastion SSM agent to come back online..."
  for _ in $(seq 1 30); do
    state=$(aws ssm describe-instance-information --region "$region" \
      --filters "Key=InstanceIds,Values=${bastion_id}" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
    [ "$state" = "Online" ] && break
    sleep 10
  done
  if [ "${state:-}" != "Online" ]; then
    echo "WARNING: bastion SSM agent did not come online within 5 minutes -- check it manually." >&2
  fi
fi

echo "All instances running."
