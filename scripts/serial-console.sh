#!/usr/bin/env bash
# Opens an interactive EC2 Serial Console session to a running instance --
# the only reliable live-output signal in this account. See
# docs/runbook.md's Troubleshooting section: `aws ec2 get-console-output` has
# sent this project down two dead ends, showing nothing at all for an
# instance demonstrably alive at 500+ seconds of uptime.
#
# Two traps this script exists to encode:
#  - The regional endpoint here is non-standard:
#    ec2-serial-console.<region>.api.aws, not the
#    serial-console.ec2-instance-connect.<region>.amazonaws.com form most
#    documentation shows.
#  - The pushed SSH key is valid for about 60 seconds. Push and connect
#    back-to-back -- this script does the push and immediately execs ssh
#    with the terminal handed straight through, so there's no FIFO/pipe
#    trick needed and nothing between push and connect to burn the window.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: serial-console.sh -a <account-alias> --instance <instance-id> [--ssh-key <path>]" >&2
  exit 1
}

account_alias=""
instance_id=""
ssh_key="$HOME/.ssh/id_rsa.pub"
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --instance)
      instance_id="$2"
      shift 2
      ;;
    --ssh-key)
      ssh_key="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] && [ -n "$instance_id" ] || usage

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
[ -f "$ssh_key" ] || {
  echo "ERROR: $ssh_key not found. Pass --ssh-key <path> if it's elsewhere." >&2
  exit 1
}

echo "Enabling serial console access (account-level, idempotent)..." >&2
aws ec2 enable-serial-console-access --region "$region" >/dev/null

echo "Pushing SSH key (valid ~60s) and connecting immediately..." >&2
aws ec2-instance-connect send-serial-console-ssh-public-key --region "$region" \
  --instance-id "$instance_id" --ssh-public-key "file://$ssh_key" >/dev/null

exec ssh "${instance_id}.port0@ec2-serial-console.${region}.api.aws"
