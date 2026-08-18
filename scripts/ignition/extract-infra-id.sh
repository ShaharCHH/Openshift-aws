#!/usr/bin/env bash
# Prints the cluster's infraID, read straight out of the locally-generated
# metadata.json (e.g. "horizon-7t7mq").
#
# Feeds terraform's cluster_infra_id variable -- master/bootstrap instances
# get tagged kubernetes.io/cluster/<infraID>=owned, which the in-cluster AWS
# cloud-controller-manager requires to identify its own cluster and
# initialize any node at all. Confirmed for real: without it,
# aws-cloud-controller-manager fails with "AWS cloud failed to find
# ClusterID", every node keeps its automatic
# node.cloudprovider.kubernetes.io/uninitialized taint forever, and nothing
# else in the cluster (starting with the network operator/CNI) can ever
# schedule. See ~/.claude/plans/soft-orbiting-puzzle.md's "masters reject
# bootstrap's MCS certificate" section's follow-on for the full trail.
#
# infraID is regenerated fresh on every `openshift-install create manifests`
# run (random suffix), same as master.ign's CA -- not something committed to
# accounts/*.tfvars, passed via -var like rhcos_ami_id and mcs_ca_data_url.
set -euo pipefail

usage() {
  echo "usage: extract-infra-id.sh -a <account-alias>" >&2
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
metadata_json="$repo_root/.ignition/${account_alias}/metadata.json"
[ -f "$metadata_json" ] || {
  echo "ERROR: $metadata_json not found -- run generate-ignition.sh first." >&2
  exit 1
}

jq -r '.infraID' "$metadata_json"
