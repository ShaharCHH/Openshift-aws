#!/usr/bin/env bash
# Orchestrates the full account preflight: live terraform-test canaries +
# SCP-denial probes. Safe to run against a brand-new/unknown AWS account —
# guarantees a cleanup sweep even on failure or interrupt (see
# cleanup-orphans.sh, invoked from the EXIT trap below).
set -uo pipefail

usage() {
  echo "usage: run-all.sh -a <account-alias>"
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=../lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"
tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found. Copy accounts/example.tfvars.sample first." >&2
  exit 1
}

aws_region=$(read_tfvar aws_region "$tfvars")
existing_vpc_id=$(read_tfvar existing_vpc_id "$tfvars")
existing_private_subnet_id=$(read_tfvar existing_private_subnet_id "$tfvars")
if [ -z "$aws_region" ] || [ -z "$existing_vpc_id" ] || [ -z "$existing_private_subnet_id" ]; then
  echo "ERROR: aws_region / existing_vpc_id / existing_private_subnet_id must all be set in $tfvars" >&2
  exit 1
fi

echo "Preflight target: account-alias=${account_alias} region=${aws_region}"
echo "Verifying caller identity..."
aws sts get-caller-identity --region "$aws_region" || {
  echo "ERROR: no valid AWS credentials for this shell." >&2
  exit 1
}

account_id=$(aws sts get-caller-identity --query Account --output text)
run_id="ocp-preflight-${account_id}-$(date +%s)"
report_dir="$repo_root/preflight/reports"
mkdir -p "$report_dir"
stamp=$(date +%s)
tf_json_log="$report_dir/${account_alias}-${stamp}-tftest.jsonl"
scp_log="$report_dir/${account_alias}-${stamp}-scp-probes.log"

cleanup() {
  echo
  echo "Running orphan sweep (backstop cleanup)..."
  "$script_dir/cleanup-orphans.sh" "$aws_region" || true
}
trap cleanup EXIT

echo
echo "=== Live canaries (terraform test) ==="
(
  cd "$repo_root/preflight" && terraform init -input=false >/dev/null && \
  terraform test -json \
    -var="aws_region=${aws_region}" \
    -var="existing_vpc_id=${existing_vpc_id}" \
    -var="existing_private_subnet_id=${existing_private_subnet_id}" \
    -var="name_prefix=${run_id}"
) >"$tf_json_log" 2>&1
tf_rc=$?
echo "terraform test exit code: $tf_rc (see $tf_json_log)"

echo
echo "=== SCP-denial probes (raw aws-cli) ==="
SCP_PROBE_RESULTS="$scp_log" "$script_dir/scp-probes.sh" "$aws_region" "$existing_vpc_id" "$existing_private_subnet_id"
scp_rc=$?

echo
"$script_dir/report.sh" "$tf_json_log" "$scp_log" "$report_dir/${account_alias}-${stamp}-summary"
report_rc=$?

if [ $tf_rc -ne 0 ] || [ $scp_rc -ne 0 ] || [ $report_rc -ne 0 ]; then
  exit 1
fi
exit 0
