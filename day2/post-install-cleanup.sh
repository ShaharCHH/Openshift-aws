#!/usr/bin/env bash
# The three things the installer/storage design leaves in a state that needs
# a decision, per docs/runbook.md's "Post-install cleanup". Each step
# verifies its own result rather than assuming success -- two of these were
# previously done wrong on this cluster, and the third has never been tried.
#
# 1. Puts the storage operator back to managementState: Managed. An earlier
#    handoff set it to Removed, which the operator does not support --
#    confirmed for real: "ManagementStateDegraded: Removed is not supported
#    for storage operator", a SECOND degraded condition stacked on the one
#    that patch was meant to clear.
# 2. Tries the supported lever instead: managementState: Removed on the
#    ClusterCSIDriver object itself (ebs.csi.aws.com), not the operator.
#    UNTESTED as of this script's writing -- reads the value back rather
#    than assuming the patch stuck.
# 3. Only if (2) actually stuck: deletes the StorageClasses that can never
#    provision here (gp3-csi, gp2-csi -- their driver has no credential to
#    reach AWS with; see docs/architecture.md). If (2) was refused, the
#    driver operator will just recreate them, so this falls back to the
#    current behaviour (de-annotating gp3-csi as default) instead.
# 4. Confirms efs-nfs is left as the sole default StorageClass.
# 5. Prints the condition messages of the three operators expected to stay
#    Degraded/Progressing forever on this platform (control-plane-machine-set,
#    storage, network), so a genuinely NEW failure doesn't get waved off as
#    the known one -- see docs/runbook.md's "Known-inert, do not chase".
set -uo pipefail # NOT -e: several steps here are expected-possible failures
                 # (the untested lever, the known-refused operator patch),
                 # inspected and reported on, not fatal to the whole run.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: post-install-cleanup.sh -a <account-alias>" >&2
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

kubeconfig="$repo_root/.ignition/${account_alias}/auth/kubeconfig"
[ -f "$kubeconfig" ] || {
  echo "ERROR: $kubeconfig not found." >&2
  exit 1
}
command -v oc >/dev/null 2>&1 || {
  echo "ERROR: oc not found on PATH." >&2
  exit 1
}

oc_cmd() { oc --kubeconfig "$kubeconfig" "$@"; }

echo "=== 1/5: storage operator managementState -> Managed ===" >&2
oc_cmd patch storage cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
current_mgmt=$(oc_cmd get storage cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "Unknown")
echo "storage cluster managementState is now: $current_mgmt" >&2
if [ "$current_mgmt" != "Managed" ]; then
  echo "WARNING: expected Managed, got $current_mgmt -- inspect manually." >&2
fi

echo >&2
echo "=== 2/5: try the supported lever -- ClusterCSIDriver ebs.csi.aws.com -> Removed ===" >&2
echo "(UNTESTED as of this script's writing -- verifying the result, not assuming it)" >&2
before=$(oc_cmd get clustercsidriver ebs.csi.aws.com -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "Unknown")
echo "before: $before" >&2
patch_out=$(oc_cmd patch clustercsidriver ebs.csi.aws.com --type=merge \
  -p '{"spec":{"managementState":"Removed"}}' 2>&1)
patch_rc=$?
echo "$patch_out" >&2
csidriver_removed=false
if [ $patch_rc -eq 0 ]; then
  sleep 10
  after=$(oc_cmd get clustercsidriver ebs.csi.aws.com -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "Unknown")
  echo "after: $after" >&2
  if [ "$after" = "Removed" ]; then
    csidriver_removed=true
    echo "RESULT: the ClusterCSIDriver lever WORKS on this platform." >&2
  else
    echo "RESULT: patch call succeeded but the value did not stick (now: $after) -- refused/reconciled back." >&2
  fi
else
  echo "RESULT: patch call itself was rejected -- see output above." >&2
fi

echo >&2
echo "=== 3/5: StorageClasses that can never provision here ===" >&2
if [ "$csidriver_removed" = "true" ]; then
  echo "ClusterCSIDriver removal stuck -- deleting gp3-csi/gp2-csi outright." >&2
  oc_cmd delete sc gp3-csi gp2-csi --ignore-not-found
  sleep 60
  still_here=$(oc_cmd get sc gp3-csi gp2-csi --ignore-not-found -o name 2>/dev/null || echo "")
  if [ -n "$still_here" ]; then
    echo "WARNING: recreated after ~60s despite the driver removal: $still_here" >&2
    echo "Falling back to de-annotating instead." >&2
    oc_cmd patch storageclass gp3-csi -p \
      '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
  else
    echo "Confirmed gone." >&2
  fi
else
  echo "ClusterCSIDriver removal did not stick -- the operator would just recreate" >&2
  echo "gp3-csi/gp2-csi if deleted. Falling back to de-annotating as default instead" >&2
  echo "(current behaviour, safe under this outcome)." >&2
  oc_cmd patch storageclass gp3-csi -p \
    '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
fi

echo >&2
echo "=== 4/5: efs-nfs must be the sole default StorageClass ===" >&2
defaults=$(oc_cmd get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
echo "Default StorageClass(es): $defaults" >&2
if [ "$defaults" != "efs-nfs" ]; then
  echo "WARNING: expected efs-nfs to be the only default, got: $defaults" >&2
fi

echo >&2
echo "=== 5/5: known-inert operators -- confirming they're broken for the expected reason ===" >&2
"$repo_root/scripts/check-known-inert.sh" -a "$account_alias" || true

echo >&2
echo "Done. See docs/runbook.md's Post-install cleanup section for the full context" >&2
echo "behind each step." >&2
