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

# Splits a multi-cert PEM bundle into cert-1.pem, cert-2.pem, ... in $2.
# Same approach as scripts/trust-cluster-ca.sh's split_pem_bundle --
# `openssl x509` on its own only ever reads the FIRST cert in a bundle.
split_pem_bundle() {
  local bundle="$1" outdir="$2"
  mkdir -p "$outdir"
  awk -v dir="$outdir" '
    /-----BEGIN CERTIFICATE-----/ { n++; capturing=1 }
    capturing { print > (dir "/cert-" n ".pem") }
    /-----END CERTIFICATE-----/ { capturing=0 }
  ' "$bundle"
}

# Prints the SHA-1 fingerprint of the kube-apiserver-lb-signer cert inside a
# base64 certificate-authority-data value read from stdin, empty if absent.
lb_signer_fingerprint() {
  local tmp f fp=""
  tmp=$(mktemp -d)
  base64 -d > "$tmp/bundle.pem" 2>/dev/null
  split_pem_bundle "$tmp/bundle.pem" "$tmp/split"
  for f in "$tmp/split"/cert-*.pem; do
    [ -e "$f" ] || continue
    if openssl x509 -noout -subject -in "$f" 2>/dev/null | grep -q "kube-apiserver-lb-signer"; then
      fp=$(openssl x509 -noout -fingerprint -sha1 -in "$f" 2>/dev/null)
    fi
  done
  rm -rf "$tmp"
  [ -n "$fp" ] && echo "$fp"
}

if [ -f "$target" ]; then
  backup="$target.bak-$(date +%s)"
  cp "$target" "$backup"
  echo "Backed up existing kubeconfig to $backup"
fi

# Renamed source first: kubectl's merge takes the FIRST file's value for a
# conflicting key, and after a cluster rebuild $target still holds the
# previous generation's cluster entry (and CA) under this same alias.
# Target-first silently kept a stale CA here and reported success -- seen
# for real 27 Aug 2026, producing an x509 "unknown authority" loop on
# `oc get no` that persisted even after scripts/trust-cluster-ca.sh (which
# can't help -- oc never consults the OS trust store, only this file).
KUBECONFIG="$renamed_kubeconfig:$target" oc config view --flatten > "$merged_kubeconfig"

# Guard against a repeat: confirm the merge actually picked up the source's
# API CA rather than silently keeping whatever $target had for this alias.
source_ca_b64=$(jq -r '.clusters[0].cluster."certificate-authority-data" // empty' <<<"$source_json")
merged_ca_b64=$(oc config view --kubeconfig="$merged_kubeconfig" --raw -o json |
  jq -r --arg a "$account_alias" '.clusters[] | select(.name == $a) | .cluster."certificate-authority-data" // empty')

source_fp=$(lb_signer_fingerprint <<<"$source_ca_b64")
merged_fp=$(lb_signer_fingerprint <<<"$merged_ca_b64")

if [ -n "$source_fp" ] && [ "$source_fp" != "$merged_fp" ]; then
  echo "ERROR: merge did not pick up the source's API CA -- refusing to write $target." >&2
  echo "  source lb-signer: $source_fp" >&2
  echo "  merged lb-signer: $merged_fp" >&2
  exit 1
fi

mv "$merged_kubeconfig" "$target"
oc --kubeconfig "$target" config use-context "$account_alias" >/dev/null

echo "Merged '$account_alias' into $target (context/cluster/user all named '$account_alias', now current)."
echo ""
echo "Still needed to actually reach the API:"
echo "  - scripts/tunnel.sh -a $account_alias running (forwards 127.0.0.1:6443)"
echo "  - /etc/hosts: 127.0.0.1  api.${cluster_name}.${base_domain}"
echo "    (tunnel.sh prints this line if it's missing)"
