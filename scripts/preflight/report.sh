#!/usr/bin/env bash
# Merges a `terraform test -json` log and an scp-probes.sh log into one
# pass/fail table + a JSON summary file. Exit code reflects the combined
# verdict: any failed canary, any UNEXPECTED_SUCCESS, any INCONCLUSIVE, or
# any BLOCKED SCP probe fails the whole preflight run. BLOCKED is the
# opposite polarity of UNEXPECTED_SUCCESS -- it's what scp-probes.sh's
# expected-to-succeed EFS probe reports when it comes back denied instead.
set -euo pipefail

tf_test_json="${1:?usage: report.sh <terraform-test-json-log> <scp-probes-log> <out-prefix>}"
scp_log="${2:?}"
out_prefix="${3:?}"

mkdir -p "$(dirname "$out_prefix")"

# terraform test -json emits one line per event; a run's final result is a
# `type=="test_run"` event with `test_run.progress=="complete"` and a
# `test_run.status` of "pass"/"error"/"skip" (confirmed against real output —
# there is no `type=="test_result"`, despite what an earlier version of this
# script assumed).
tf_summary=$(jq -s '
  [ .[] | select(.type == "test_run" and .test_run.progress == "complete") ]
  | map({file: .["@testfile"], run: .["@testrun"], status: .test_run.status})
' "$tf_test_json" 2>/dev/null || echo "[]")

tf_failed=$(echo "$tf_summary" | jq '[.[] | select(.status != "pass" and .status != "skip")] | length')

scp_unexpected=$(grep -c '^UNEXPECTED_SUCCESS' "$scp_log" || true)
scp_inconclusive=$(grep -c '^INCONCLUSIVE' "$scp_log" || true)
scp_blocked=$(grep -c '^BLOCKED' "$scp_log" || true)

report="${out_prefix}.json"
jq -n \
  --argjson terraform_tests "$tf_summary" \
  --argjson terraform_failed "${tf_failed:-0}" \
  --argjson scp_unexpected_success "${scp_unexpected:-0}" \
  --argjson scp_inconclusive "${scp_inconclusive:-0}" \
  --argjson scp_blocked "${scp_blocked:-0}" \
  '{
     terraform_tests: $terraform_tests,
     terraform_failed: $terraform_failed,
     scp_unexpected_success: $scp_unexpected_success,
     scp_inconclusive: $scp_inconclusive,
     scp_blocked: $scp_blocked
   }' >"$report"

echo "=== Preflight Report ==="
echo "Terraform canaries:"
echo "$tf_summary" | jq -r '.[] | "  \(.status | ascii_upcase)\t\(.file) :: \(.run)"'
echo
echo "SCP probes: see ${scp_log}"
echo

if [ "${tf_failed:-0}" -gt 0 ] || [ "${scp_unexpected:-0}" -gt 0 ] || [ "${scp_inconclusive:-0}" -gt 0 ] || [ "${scp_blocked:-0}" -gt 0 ]; then
  echo "RESULT: FAIL — see ${report}"
  exit 1
else
  echo "RESULT: PASS — see ${report}"
  exit 0
fi
