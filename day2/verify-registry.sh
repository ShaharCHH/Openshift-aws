#!/usr/bin/env bash
# Proves the internal image registry can actually store and serve an image,
# not just that the clusteroperator reports Available=True -- confirms the
# blobs really landed on EFS rather than somewhere ephemeral, and checks the
# external route day2/setup-registry.sh applies is healthy (reencrypt,
# admitted). Replaces the manual round-trip in docs/runbook.md's Phase 9.
#
# If the build fails with `InvalidOutputReference` / `Output image could not
# be resolved`, that means openshift-controller-manager is still holding the
# registry's old, empty internalRegistryHostname from before setup-registry.sh
# ran -- it doesn't pick up the new value on its own. This script restarts it
# and retries once, since both were hit for real on this cluster and neither
# error names the actual cause.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: verify-registry.sh -a <account-alias>" >&2
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

# `oc new-project` below switches the current context and writes that back
# into whatever kubeconfig it was given. Pointing that at the admin
# kubeconfig corrupts it from a 1/1/1 admin shape into a multi-context one,
# which then trips the shape guard in scripts/update-kubeconfig.sh -- seen
# for real 27 Aug 2026, 8 minutes after a kubeconfig merge, leaving that
# script unable to run again until the file was repaired by hand. Work on a
# throwaway copy instead.
scratch_kubeconfig="$(mktemp)"
cp "$kubeconfig" "$scratch_kubeconfig"
kubeconfig="$scratch_kubeconfig"

oc_cmd() { oc --kubeconfig "$kubeconfig" "$@"; }

project="registry-verify-$(date +%s)"
build_dir=""

cleanup() {
  oc_cmd delete project "$project" --ignore-not-found >/dev/null 2>&1 || true
  [ -n "$build_dir" ] && rm -rf "$build_dir"
  rm -f "$scratch_kubeconfig"
}
trap cleanup EXIT

build_dir="$(mktemp -d)"
cat > "$build_dir/Dockerfile" <<'EOF'
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
RUN echo "registry-verify-ok" > /test.txt
EOF

echo "Creating throwaway project $project..." >&2
oc_cmd new-project "$project" >/dev/null

echo "Starting build (binary, docker strategy)..." >&2
oc_cmd -n "$project" new-build --name=roundtrip --binary --strategy=docker >/dev/null

run_build() {
  oc_cmd -n "$project" start-build roundtrip --from-dir="$build_dir" --follow 2>&1
}

build_log=$(run_build) || true
echo "$build_log"

if echo "$build_log" | grep -qi 'InvalidOutputReference\|Output image could not be resolved'; then
  echo >&2
  echo "Hit InvalidOutputReference -- restarting openshift-controller-manager and retrying once..." >&2
  oc_cmd delete pods -n openshift-controller-manager --all >/dev/null
  oc_cmd -n "$project" rollout status deploymentconfig/roundtrip --timeout=10s >/dev/null 2>&1 || true
  sleep 15
  build_log=$(run_build) || true
  echo "$build_log"
fi

if ! echo "$build_log" | grep -qi 'Push successful'; then
  echo "FAIL: build never reported a successful push. See log above." >&2
  exit 1
fi

echo >&2
echo "Pulling the built image back from the internal registry..." >&2
oc_cmd -n "$project" run pulltest \
  --image="image-registry.openshift-image-registry.svc:5000/${project}/roundtrip:latest" \
  --restart=Never --command -- cat /test.txt >/dev/null

pull_phase="Pending"
for _ in $(seq 1 24); do
  pull_phase=$(oc_cmd -n "$project" get pod pulltest -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  case "$pull_phase" in Succeeded | Failed) break ;; esac
  sleep 5
done

pull_log=$(oc_cmd -n "$project" logs pulltest 2>&1 || echo "")
echo "$pull_log"

if [ "$pull_phase" != "Succeeded" ] || ! echo "$pull_log" | grep -q "registry-verify-ok"; then
  echo "FAIL: pull-back did not produce the expected file content." >&2
  exit 1
fi

echo >&2
echo "Confirming the blobs actually landed on EFS..." >&2
reg_pod=$(oc_cmd get pods -n openshift-image-registry -l docker-registry=default -o name | head -1)
[ -n "$reg_pod" ] || {
  echo "ERROR: no running image-registry pod found." >&2
  exit 1
}
mount_line=$(oc_cmd exec -n openshift-image-registry "$reg_pod" -- sh -c 'mount | grep " /registry "' 2>/dev/null || echo "")
echo "$mount_line" >&2
oc_cmd exec -n openshift-image-registry "$reg_pod" -- sh -c \
  'df -h /registry; ls /registry/docker/registry/v2/repositories/' >&2

if ! echo "$mount_line" | grep -qE '\.efs\.[a-z0-9-]+\.amazonaws\.com:/openshift/'; then
  echo "FAIL: /registry is not mounted from EFS's /openshift export -- got: $mount_line" >&2
  exit 1
fi

echo >&2
echo "Checking the external route (day2/setup-registry.sh always applies it)..." >&2
termination=$(oc_cmd get route registry -n openshift-image-registry \
  -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
admitted=$(oc_cmd get route registry -n openshift-image-registry \
  -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || echo "")
route_host=$(oc_cmd get route registry -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [ "$termination" != "reencrypt" ]; then
  echo "FAIL: route 'registry' is '$termination', not reencrypt -- see manifests/registry/registry-route.yaml for why passthrough doesn't work." >&2
  exit 1
fi
if [ "$admitted" != "True" ]; then
  echo "FAIL: route 'registry' is not Admitted." >&2
  exit 1
fi
echo "Route OK: $route_host (reencrypt, admitted)." >&2

# Reaching the route from wherever this script runs needs the console/443
# tunnel and *.apps DNS (docs/runbook.md's Phase 9) -- neither is guaranteed
# on the machine running this script (e.g. run from the bastion, which
# resolves *.apps itself but has no reason to run the tunnel). Treat
# reachability as best-effort: report it, don't fail the round-trip on it.
if command -v curl >/dev/null 2>&1; then
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://${route_host}/v2/" 2>/dev/null || echo "000")
  if [ "$http_code" = "000" ]; then
    echo "NOTE: https://${route_host}/v2/ not reachable from this machine (got no response) -- expected unless the console tunnel and *.apps DNS are set up here (docs/runbook.md's Phase 9). The route itself is healthy." >&2
  else
    echo "External route reachable and serving valid TLS: https://${route_host}/v2/ -> HTTP $http_code." >&2
  fi
else
  echo "NOTE: curl not on PATH, skipping external reachability check." >&2
fi

echo >&2
echo "PASS: build -> push -> pull round-trip verified, blobs confirmed on EFS, external route healthy." >&2
