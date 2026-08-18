#!/usr/bin/env bash
# Prints the `data:...;base64,...` URL for the cluster's root-ca, read
# straight out of the locally-generated master.ign
# (ignition.security.tls.certificateAuthorities[0].source).
#
# Feeds terraform/modules/control-plane's mcs_ca_data_url variable -- the
# wrapper ignition embeds this CA directly rather than relying on
# master.ign's own self-referential declaration, which isn't trusted in time
# for master.ign's own config.merge fetch to api-int. See
# ~/.claude/plans/soft-orbiting-puzzle.md's "masters reject bootstrap's MCS
# certificate" section for the full trail.
set -euo pipefail

usage() {
  echo "usage: extract-mcs-ca.sh -a <account-alias>" >&2
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
master_ign="$repo_root/.ignition/${account_alias}/master.ign"
[ -f "$master_ign" ] || {
  echo "ERROR: $master_ign not found -- run generate-ignition.sh first." >&2
  exit 1
}

jq -r '.ignition.security.tls.certificateAuthorities[0].source' "$master_ign"
