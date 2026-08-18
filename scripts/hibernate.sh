#!/usr/bin/env bash
# Stops (not terminates) every EC2 instance belonging to this deployment, to
# pause compute billing between work sessions (overnight, etc.).
#
# IMPORTANT: this only pauses compute. Attached EBS volumes keep billing
# whether the instance is running or stopped -- see docs/architecture.md's
# cost notes. Stop/start is for gaps *within* an active work stretch (a few
# days); for a longer gap, destroy instead of leaving this hibernating.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: hibernate.sh -a <account-alias>"
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
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -z "$ids" ]; then
  echo "No running instances found for account-alias=${account_alias}. Nothing to do."
  exit 0
fi

# shellcheck disable=SC2086
echo "Stopping: $ids"
# shellcheck disable=SC2086
aws ec2 stop-instances --region "$region" --instance-ids $ids >/dev/null
# shellcheck disable=SC2086
aws ec2 wait instance-stopped --region "$region" --instance-ids $ids

echo "Stopped. Compute billing paused -- attached EBS volumes still bill regardless."
