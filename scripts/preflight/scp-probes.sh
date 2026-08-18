#!/usr/bin/env bash
# Probes AWS API calls that SHOULD be denied by this account's SCP:
# ec2:CreateVpc, ec2:AllocateAddress, elasticloadbalancing:CreateLoadBalancer,
# ec2:CopySnapshot. Each is expected to FAIL with an authorization error —
# an unexpected SUCCESS means the bastion/HAProxy/existing-VPC/UPI
# workarounds may not be needed on this account, and is flagged loudly
# rather than silently treated as a pass. Deliberately not `terraform test`:
# an SCP explicit-deny is a raw provider API error, not a checkable
# validation/precondition/postcondition Terraform's test framework can
# assert against.
set -uo pipefail # NOT -e: failures here are expected and inspected, not fatal

region="${1:?usage: scp-probes.sh <region> <existing-vpc-id> <existing-private-subnet-id>}"
vpc_id="${2:?}"
subnet_id="${3:?}"

RESULTS_FILE="${SCP_PROBE_RESULTS:-/dev/stdout}"
overall_rc=0

classify() {
  local name="$1" rc="$2" output="$3"
  if [ "$rc" -eq 0 ]; then
    echo "UNEXPECTED_SUCCESS  $name" | tee -a "$RESULTS_FILE"
    overall_rc=1
    return 1 # signal caller to run its cleanup
  fi
  if echo "$output" | grep -qiE 'unauthorized|accessdenied|explicit deny|not authorized'; then
    echo "PASS                $name  (denied, as expected)" | tee -a "$RESULTS_FILE"
    return 0
  fi
  echo "INCONCLUSIVE        $name  -- ${output//$'\n'/ }" | tee -a "$RESULTS_FILE"
  overall_rc=1
  return 0
}

echo "=== SCP probes: $region ===" | tee -a "$RESULTS_FILE"

# --- ec2:CreateVpc ---
out=$(aws ec2 create-vpc --region "$region" \
  --cidr-block 10.255.255.0/28 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Purpose,Value=ocp-preflight-scp-probe}]' 2>&1)
rc=$?
if ! classify "ec2:CreateVpc" "$rc" "$out"; then
  probe_vpc_id=$(echo "$out" | grep -o 'vpc-[a-z0-9]*' | head -1)
  [ -n "$probe_vpc_id" ] && aws ec2 delete-vpc --region "$region" --vpc-id "$probe_vpc_id" >/dev/null 2>&1
fi

# --- ec2:AllocateAddress ---
out=$(aws ec2 allocate-address --region "$region" --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Purpose,Value=ocp-preflight-scp-probe}]' 2>&1)
rc=$?
if ! classify "ec2:AllocateAddress" "$rc" "$out"; then
  alloc_id=$(echo "$out" | grep -o 'eipalloc-[a-z0-9]*' | head -1)
  [ -n "$alloc_id" ] && aws ec2 release-address --region "$region" --allocation-id "$alloc_id" >/dev/null 2>&1
fi

# --- elasticloadbalancing:CreateLoadBalancer ---
# Uses the REAL existing subnet so a parameter-validation error can't
# masquerade as the SCP-denial answer.
out=$(aws elbv2 create-load-balancer --region "$region" \
  --name "ocp-preflight-scp-probe" --type network --subnets "$subnet_id" 2>&1)
rc=$?
if ! classify "elasticloadbalancing:CreateLoadBalancer" "$rc" "$out"; then
  lb_arn=$(echo "$out" | grep -o 'arn:aws:elasticloadbalancing:[^"]*loadbalancer/[^"]*' | head -1)
  [ -n "$lb_arn" ] && aws elbv2 delete-load-balancer --region "$region" --load-balancer-arn "$lb_arn" >/dev/null 2>&1
fi

# --- ec2:CopySnapshot ---
# Needs a source snapshot to copy; create a tiny throwaway volume+snapshot
# first. Wrapped in a function so `trap ... RETURN` cleans up its own
# prerequisites regardless of how the probe itself turns out.
probe_copy_snapshot() {
  local vol_id="" snap_id="" copy_snap_id="" az out rc
  # shellcheck disable=SC2064
  trap '
    [ -n "$copy_snap_id" ] && aws ec2 delete-snapshot --region "'"$region"'" --snapshot-id "$copy_snap_id" >/dev/null 2>&1
    [ -n "$snap_id" ] && aws ec2 delete-snapshot --region "'"$region"'" --snapshot-id "$snap_id" >/dev/null 2>&1
    [ -n "$vol_id" ] && aws ec2 delete-volume --region "'"$region"'" --volume-id "$vol_id" >/dev/null 2>&1
  ' RETURN

  az=$(aws ec2 describe-subnets --region "$region" --subnet-ids "$subnet_id" \
    --query 'Subnets[0].AvailabilityZone' --output text)
  vol_id=$(aws ec2 create-volume --region "$region" --availability-zone "$az" --size 1 \
    --tag-specifications 'ResourceType=volume,Tags=[{Key=Purpose,Value=ocp-preflight-scp-probe}]' \
    --query 'VolumeId' --output text)
  aws ec2 wait volume-available --region "$region" --volume-ids "$vol_id"
  snap_id=$(aws ec2 create-snapshot --region "$region" --volume-id "$vol_id" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Purpose,Value=ocp-preflight-scp-probe}]' \
    --query 'SnapshotId' --output text)
  aws ec2 wait snapshot-completed --region "$region" --snapshot-ids "$snap_id"

  out=$(aws ec2 copy-snapshot --region "$region" --source-region "$region" --source-snapshot-id "$snap_id" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Purpose,Value=ocp-preflight-scp-probe}]' 2>&1)
  rc=$?
  if ! classify "ec2:CopySnapshot" "$rc" "$out"; then
    copy_snap_id=$(echo "$out" | grep -o 'snap-[a-z0-9]*' | head -1)
  fi
}
probe_copy_snapshot

exit "$overall_rc"
