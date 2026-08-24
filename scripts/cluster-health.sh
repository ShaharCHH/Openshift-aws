#!/usr/bin/env bash
# `oc get clusteroperators`, with the three operators expected to stay
# unhealthy forever on this platform (control-plane-machine-set, storage,
# network -- see docs/runbook.md's "Known-inert, do not chase") called out
# separately from everything else, so a genuinely new problem doesn't get
# lost in three rows of expected noise. Run this whenever something looks
# off; for a deeper check that the known-inert three are broken for the
# expected reason specifically, see check-known-inert.sh.
set -uo pipefail # NOT -e: a real finding here is the point, not a reason
                 # to abort before reporting it.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: cluster-health.sh -a <account-alias>" >&2
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

known_inert="control-plane-machine-set storage network"

echo "=== Known-inert (expected unhealthy on this platform -- see docs/runbook.md) ==="
# shellcheck disable=SC2086  # deliberately unquoted -- $known_inert is a
# space-separated list of resource names, not a single argument
oc --kubeconfig "$kubeconfig" get co $known_inert 2>/dev/null

echo
echo "=== Everything else ==="
all_names=$(oc --kubeconfig "$kubeconfig" get co -o jsonpath='{.items[*].metadata.name}')
other_names=""
for name in $all_names; do
  case " $known_inert " in *" $name "*) continue ;; esac
  other_names="${other_names}${other_names:+ }${name}"
done
# shellcheck disable=SC2086  # same as above
oc --kubeconfig "$kubeconfig" get co $other_names

# shellcheck disable=SC2086  # same as above
unhealthy=$(oc --kubeconfig "$kubeconfig" get co $other_names -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Available")].status}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' \
  | awk '$2 != "True" || $3 != "False" { print $1 }')

if [ -n "$unhealthy" ]; then
  echo
  echo "WARNING: unhealthy operator(s) outside the known-inert list:" >&2
  echo "$unhealthy" >&2
  exit 1
fi

echo
echo "OK: everything outside the known-inert list is Available/not-Degraded."
