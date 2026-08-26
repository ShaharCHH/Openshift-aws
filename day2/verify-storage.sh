#!/usr/bin/env bash
# Proves efs-nfs actually provisions, not just that the StorageClass object
# exists. A StorageClass with no working provisioner behind it looks
# identical to a working one until something tries to bind against it --
# see docs/runbook.md's Phase 8. Creates a scratch RWX PVC, waits for Bound,
# deletes it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: verify-storage.sh -a <account-alias>" >&2
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

pvc_name="storage-verify-$(date +%s)"

cleanup() {
  oc_cmd delete pvc "$pvc_name" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Creating scratch PVC $pvc_name on efs-nfs..." >&2
cat <<EOF | oc_cmd apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-nfs
  resources:
    requests:
      storage: 1Gi
EOF

echo "Waiting for Bound (up to 60s)..." >&2
phase="Pending"
for _ in $(seq 1 12); do
  phase=$(oc_cmd get pvc "$pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [ "$phase" = "Bound" ] && break
  sleep 5
done

if [ "$phase" != "Bound" ]; then
  echo "FAIL: PVC $pvc_name never reached Bound (last phase: $phase)." >&2
  echo "Check the nfs-provisioner pod: oc --kubeconfig $kubeconfig -n nfs-provisioner get pods,events" >&2
  exit 1
fi

echo "PASS: efs-nfs provisions and binds." >&2
