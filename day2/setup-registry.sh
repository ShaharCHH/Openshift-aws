#!/usr/bin/env bash
# Enables the internal image registry, backed by a PVC on efs-nfs instead of
# its native S3 backend -- the registry runs as a pod, and no pod here can
# hold an AWS credential (docs/architecture.md's storage section) -- and
# exposes it outside the cluster with the reencrypt route from
# manifests/registry/registry-route.yaml, so it can be reached with
# podman/skopeo/oc image from a laptop, not just from in-cluster builds.
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

# A passthrough route (hand-created, or from an earlier attempt) claims the
# same "registry" hostname as the reencrypt one below and fails the same way
# documented in manifests/registry/registry-route.yaml: the pod's
# service-ca-signed cert has no SAN for any route hostname, so external
# clients get a hostname-mismatch error no matter which CA they trust.
existing_termination=$(oc_cmd get route registry -n openshift-image-registry \
  -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
if [ -n "$existing_termination" ] && [ "$existing_termination" != "reencrypt" ]; then
  echo "Removing existing '$existing_termination' route named 'registry' -- it would conflict with the reencrypt one." >&2
  oc_cmd delete route registry -n openshift-image-registry
fi

echo "Applying the external route (reencrypt -- see manifests/registry/registry-route.yaml for why)..." >&2
oc_cmd apply -f "$repo_root/manifests/registry/registry-route.yaml"

echo "Waiting for the route to be admitted (up to 60s)..." >&2
admitted="Unknown"
for _ in $(seq 1 12); do
  admitted=$(oc_cmd get route registry -n openshift-image-registry \
    -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || echo "Unknown")
  [ "$admitted" = "True" ] && break
  sleep 5
done

route_host=$(oc_cmd get route registry -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
oc_cmd get route registry -n openshift-image-registry

if [ "$admitted" != "True" ]; then
  echo "WARNING: route not admitted yet -- inspect the route above." >&2
  exit 1
fi

echo "Done. Registry is Available and the external route ($route_host) is admitted." >&2
echo "Verify a real round-trip, including external push/pull, with day2/verify-registry.sh -a $account_alias." >&2
echo "To push from a laptop: scripts/tunnel.sh -a $account_alias --console (or --all), then either" >&2
echo "an /etc/hosts entry for $route_host or sudo scripts/setup-apps-dns.sh -a $account_alias." >&2
