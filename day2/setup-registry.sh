#!/usr/bin/env bash
# Enables the internal image registry, backed by a PVC on efs-nfs instead of
# its native S3 backend -- the registry runs as a pod, and no pod here can
# hold an AWS credential (docs/architecture.md's storage section).
#
# Replaces docs/runbook.md's Phase 9. The step people get wrong: on AWS the
# registry operator defaults spec.storage to s3, and it does NOT auto-detect
# an existing image-registry-storage PVC -- nulling s3 alone leaves storage
# empty, and the operator's own defaulter puts s3 right back (confirmed via
# its logs: "object changed: ... added:spec.storage.s3...") because
# platform-AWS defaulting runs before any PVC auto-detection. `pvc.claim` has
# to be set explicitly in the same merge patch that nulls `s3`, or the
# operator loops forever on "unable to get cluster minted credentials
# ... installer-cloud-credentials" -- it's still trying to sync the S3
# backend it just re-added.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: setup-registry.sh -a <account-alias>" >&2
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

echo "Applying registry PVC (requires efs-nfs -- run day2/apply-storage.sh first if this fails)..." >&2
oc_cmd apply -f "$repo_root/manifests/registry/registry-pvc.yaml"

echo "Waiting for image-registry-storage to bind (up to 60s)..." >&2
phase="Pending"
for _ in $(seq 1 12); do
  phase=$(oc_cmd get pvc image-registry-storage -n openshift-image-registry \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [ "$phase" = "Bound" ] && break
  sleep 5
done
if [ "$phase" != "Bound" ]; then
  echo "ERROR: image-registry-storage never reached Bound (last phase: $phase)." >&2
  exit 1
fi

echo "Nulling the S3 stanza and pointing storage at the PVC..." >&2
oc_cmd patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"storage":{"s3":null,"pvc":{"claim":"image-registry-storage"}}}}'

echo "Waiting for the image-registry clusteroperator to settle (up to 3 min)..." >&2
available="Unknown"
for _ in $(seq 1 18); do
  available=$(oc_cmd get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
  [ "$available" = "True" ] && break
  sleep 10
done

oc_cmd get co image-registry
oc_cmd get pods -n openshift-image-registry

if [ "$available" != "True" ]; then
  echo "WARNING: image-registry not Available yet -- inspect the operator/pods above." >&2
  exit 1
fi

echo "Done. Registry is Available. Verify a real round-trip with day2/verify-registry.sh -a $account_alias." >&2
