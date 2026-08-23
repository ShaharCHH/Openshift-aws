#!/usr/bin/env bash
# Merges the cluster's admin kubeconfig (.ignition/<alias>/auth/kubeconfig,
# produced by scripts/ignition/generate-ignition.sh) into a local kubeconfig,
# so `oc`/`kubectl` work against it without `export KUBECONFIG=...` every
# session.
#
# openshift-install's admin kubeconfig uses generic names (context/user
# "admin", cluster named after the infra-id). This repo is meant to be
# reused across multiple client accounts (see CLAUDE.md), and merging two
# such kubeconfigs as-is would clobber each other's "admin" entry. So this
# script renames the cluster/context/user to the account alias before
# merging -- multiple accounts then coexist as separate contexts in one
# kubeconfig, selectable with `oc config use-context <alias>`.
#
# This only touches the kubeconfig file. It does not open the SSM tunnel or
# touch /etc/hosts -- see scripts/tunnel.sh for both; like that script, this
# one only reminds you what's still needed to actually reach the API.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: update-kubeconfig.sh -a <account-alias> [--kubeconfig <path>]" >&2
  exit 1
}

account_alias=""
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --kubeconfig)
      target="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] || usage

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found." >&2
  exit 1
}

cluster_name=$(read_tfvar cluster_name "$tfvars")
base_domain=$(read_tfvar base_domain "$tfvars")
[ -n "$cluster_name" ] || {
  echo "ERROR: cluster_name not set in $tfvars" >&2
  exit 1
}
[ -n "$base_domain" ] || {
  echo "ERROR: base_domain not set in $tfvars" >&2
  exit 1
}

source_kubeconfig="$repo_root/.ignition/${account_alias}/auth/kubeconfig"
[ -f "$source_kubeconfig" ] || {
  echo "ERROR: $source_kubeconfig not found." >&2
  echo "Run scripts/ignition/generate-ignition.sh -a $account_alias first." >&2
  exit 1
}

command -v oc >/dev/null 2>&1 || {
  echo "ERROR: oc not found on PATH." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq not found on PATH." >&2
  exit 1
}

if [ -z "$target" ]; then
  target="${KUBECONFIG:-$HOME/.kube/config}"
fi
mkdir -p "$(dirname "$target")"

renamed_kubeconfig="$(mktemp)"
merged_kubeconfig="$(mktemp)"
trap 'rm -f "$renamed_kubeconfig" "$merged_kubeconfig"' EXIT

# jq needs JSON; the source is YAML, so go through `oc config view` to
# convert it rather than parsing YAML by hand.
source_json=$(oc config view --kubeconfig="$source_kubeconfig" --raw -o json)

# An openshift-install admin kubeconfig has exactly one cluster/context/user
# entry. Bail rather than guess if that shape ever changes.
counts=$(jq -r '[(.clusters | length), (.contexts | length), (.users | length)] | @tsv' \
  <<<"$source_json")
if [ "$counts" != "$(printf '1\t1\t1')" ]; then
  echo "ERROR: $source_kubeconfig doesn't look like a single-cluster admin" >&2
  echo "kubeconfig (clusters/contexts/users counts: $counts) -- refusing to guess" >&2
  echo "which entries to rename." >&2
  exit 1
fi

jq --arg alias "$account_alias" '
  .clusters[0].name = $alias |
  .users[0].name = $alias |
  .contexts[0].name = $alias |
  .contexts[0].context.cluster = $alias |
  .contexts[0].context.user = $alias |
  .["current-context"] = $alias
' <<<"$source_json" > "$renamed_kubeconfig"

if [ -f "$target" ]; then
  backup="$target.bak-$(date +%s)"
  cp "$target" "$backup"
  echo "Backed up existing kubeconfig to $backup"
fi

KUBECONFIG="$target:$renamed_kubeconfig" oc config view --flatten > "$merged_kubeconfig"
mv "$merged_kubeconfig" "$target"
oc --kubeconfig "$target" config use-context "$account_alias" >/dev/null

echo "Merged '$account_alias' into $target (context/cluster/user all named '$account_alias', now current)."
echo ""
echo "Still needed to actually reach the API:"
echo "  - scripts/tunnel.sh -a $account_alias running (forwards 127.0.0.1:6443)"
echo "  - /etc/hosts: 127.0.0.1  api.${cluster_name}.${base_domain}"
echo "    (tunnel.sh prints this line if it's missing)"
