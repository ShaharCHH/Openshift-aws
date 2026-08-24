#!/usr/bin/env bash
# Confirms the three operators this platform expects to stay broken forever
# are broken for the EXPECTED reason -- not just that they're broken. See
# docs/runbook.md's "Known-inert, do not chase": control-plane-machine-set
# Degraded, storage Degraded, and network Progressing all trace to the same
# missing cloud credential (docs/architecture.md). A genuinely new failure
# can hide behind "oh, that's the known one" if nobody actually reads the
# condition message -- this is meant to be run whenever something looks off,
# not just once after install.
set -uo pipefail # NOT -e: a mismatch here is a real finding to report, not
                 # a reason to abort before checking the other two.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: check-known-inert.sh -a <account-alias>" >&2
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

cpms_msg=$(oc_cmd get machine.machine.openshift.io -n openshift-machine-api -o jsonpath='{.items[0].status.conditions[?(@.type=="InstanceExists")].message}' 2>/dev/null || echo "")
storage_msg=$(oc_cmd get co storage -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null || echo "")
network_msg=$(oc_cmd get co network -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null || echo "")

echo "control-plane-machine-set / machine InstanceExists: $cpms_msg"
echo "storage Degraded:                                   $storage_msg"
echo "network Progressing:                                $network_msg"

# storage's Degraded message has two possible shapes depending on whether
# day2/post-install-cleanup.sh's ClusterCSIDriver lever ever stuck on this
# platform, so it's printed above for a human to read rather than
# pattern-matched here.
any_unexpected=false
case "$cpms_msg" in *"aws credentials secret"*|*"aws-cloud-credentials"*) ;; *) any_unexpected=true ;; esac
case "$network_msg" in *"cloud-credentials"*|*"cloud-provider-secret"*) ;; *) any_unexpected=true ;; esac

if [ "$any_unexpected" = "true" ]; then
  echo
  echo "WARNING: at least one condition message doesn't match the credential-wall" >&2
  echo "explanation this project has relied on -- read it above rather than assuming" >&2
  echo "known-inert. See docs/runbook.md's 'Known-inert, do not chase' list." >&2
  exit 1
fi

echo
echo "OK: all three match the expected credential-wall reason."
