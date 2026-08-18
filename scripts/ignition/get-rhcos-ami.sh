#!/usr/bin/env bash
# Resolves the RHCOS AMI id for a region + OCP minor version from Red Hat's
# authoritative CoreOS stream metadata — the same file
# `openshift-install coreos print-stream-json` reads from — without needing
# the openshift-install binary installed.
#
# EARLIER VERSION OF THIS SCRIPT WAS WRONG: it queried AWS `describe-images`
# against owner account 309956199498, filtering on name `rhcos-<minor>*`.
# That owner ID only publishes plain RHEL AMIs, not RHCOS — wrong account
# entirely. It also assumed RHCOS AMIs are named after the OCP version
# (`rhcos-4.22-...`); as of the 4.19+ dual RHEL9/RHEL10 CoreOS layers, recent
# images are instead named after the underlying RHEL version
# (`rhcos-9.8.*`, `rhcos-10.2.*`), so that filter would never have matched.
# Verified empirically against a real account: the actual RHCOS community-AMI
# publisher is 531415883065.
set -euo pipefail

region="${1:?usage: get-rhcos-ami.sh <region> [ocp-minor, e.g. 4.22] [rhel-major, 9 or 10]}"
ocp_minor="${2:-4.22}"
rhel_major="${3:-9}" # RHEL9-based RHCOS is the standard default at this point in OCP's RHEL10 migration

stream_url="https://raw.githubusercontent.com/openshift/installer/release-${ocp_minor}/data/data/coreos/coreos-rhel-${rhel_major}.json"

stream_json=$(curl -fsSL "$stream_url") || {
  echo "ERROR: failed to fetch RHCOS stream metadata from ${stream_url}" >&2
  echo "Check that release-${ocp_minor} exists in openshift/installer and that" >&2
  echo "data/data/coreos/coreos-rhel-${rhel_major}.json is still the right path for that release" >&2
  echo "(Red Hat has moved this file before — see this script's comments)." >&2
  exit 1
}

ami_id=$(echo "$stream_json" | jq -r --arg region "$region" \
  '.architectures.x86_64.images.aws.regions[$region].image // empty')

if [ -z "$ami_id" ]; then
  echo "ERROR: no RHCOS AMI found for region=${region} in ${stream_url}" >&2
  echo "This likely means Red Hat hasn't published an RHCOS AMI in this region for this" >&2
  echo "OCP release yet — importing one manually risks hitting the same ec2:CopySnapshot" >&2
  echo "SCP block this UPI design exists to avoid. Available regions:" >&2
  echo "$stream_json" | jq -r '.architectures.x86_64.images.aws.regions | keys[]' >&2
  exit 1
fi

echo "$ami_id"
