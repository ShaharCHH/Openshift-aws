#!/usr/bin/env bash
# Enables the internal image registry, backed by a PVC on efs-nfs instead of
# its native S3 backend -- the registry runs as a pod, and no pod here can
# hold an AWS credential (docs/architecture.md's storage section).
#
# Replaces docs/runbook.md's Phase 9. The step people get wrong: on AWS the
# registry operator defaults spec.storage to s3 AND auto-detects a PVC named
# image-registry-storage, filling in spec.storage.pvc too. A merge patch that
# only adds `pvc` leaves `s3` in place and the operator refuses to do
# anything ("exactly one storage type should be configured ... got 2: [S3
# PVC]") -- the S3 key has to be nulled explicitly.
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

echo "Nulling the S3 stanza (the step that trips people -- see header comment)..." >&2
oc_cmd patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"storage":{"s3":null}}}'

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
