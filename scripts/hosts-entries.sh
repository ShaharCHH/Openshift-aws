#!/usr/bin/env bash
# Writes the /etc/hosts entries scripts/tunnel.sh deliberately only warns
# about -- "/etc/hosts is the operator's file, not this script's". This one
# IS meant to write it, for whoever would rather run one opt-in command than
# copy-paste the line tunnel.sh prints.
#
# Same names tunnel.sh computes: api.<cluster>.<domain> for --api,
# console-openshift-console.apps.<cluster>.<domain> and
# oauth-openshift.apps.<cluster>.<domain> for --console (two names, not one --
# CoreDNS answers *.apps with a wildcard, /etc/hosts has no such thing, so the
# console loads and then login fails on an unresolvable name).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: hosts-entries.sh -a <account-alias> [--api] [--console] [--all]" >&2
  echo "  Defaults to --all (both) if neither flag is given." >&2
  exit 1
}

account_alias=""
want_api=false
want_console=false
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --api)
      want_api=true
      shift
      ;;
    --console)
      want_console=true
      shift
      ;;
    --all)
      want_api=true
      want_console=true
      shift
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] || usage
if [ "$want_api" = false ] && [ "$want_console" = false ]; then
  want_api=true
  want_console=true
fi

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found." >&2
  exit 1
}
cluster_name=$(read_tfvar cluster_name "$tfvars")
base_domain=$(read_tfvar base_domain "$tfvars")
[ -n "$cluster_name" ] && [ -n "$base_domain" ] || {
  echo "ERROR: cluster_name / base_domain must both be set in $tfvars" >&2
  exit 1
}

names=""
[ "$want_api" = true ] && names="${names}${names:+ }api.${cluster_name}.${base_domain}"
[ "$want_console" = true ] && names="${names}${names:+ }console-openshift-console.apps.${cluster_name}.${base_domain} oauth-openshift.apps.${cluster_name}.${base_domain}"

missing=""
for name in $names; do
  if ! awk -v n="$name" '!/^[[:space:]]*#/ && $1 == "127.0.0.1" {
         for (i = 2; i <= NF; i++) if ($i == n) found = 1
       } END { exit !found }' /etc/hosts; then
    missing="${missing}${missing:+ }${name}"
  fi
done

if [ -z "$missing" ]; then
  echo "Already present: $names"
  exit 0
fi

echo "Adding to /etc/hosts (needs sudo): $missing"
echo "127.0.0.1  ${missing}" | sudo tee -a /etc/hosts >/dev/null
echo "Done."
