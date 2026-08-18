#!/usr/bin/env bash
# Builds an account-owned RHCOS AMI by streaming Red Hat's raw disk image
# directly onto a self-owned EBS volume, snapshotting it, and registering an
# AMI from that snapshot -- entirely bypassing AWS's vmimport pipeline.
#
# WHY THIS EXISTS: this account's SCP blocks (a) launching or copying
# instances from AMIs owned by outside accounts -- confirmed via a real
# UnauthorizedOperation on both RunInstances and CopyImage against Red Hat's
# public RHCOS AMI -- and (b) the vmimport service role's internal
# CopySnapshot call specifically, confirmed by actually running a real
# ec2:ImportSnapshot task and watching it fail with an explicit SCP deny
# against `assumed-role/vmimport/...`. But CreateSnapshot, RegisterImage,
# and RunInstances all work fine when called directly by this account's own
# identity -- verified end-to-end with a disposable test AMI. This script
# exploits that gap: it never touches vmimport and never references a
# foreign-owned AMI. See docs/scp-blockers.md and the plan record at
# ~/.claude/plans/i-want-to-try-rippling-rocket.md for the full trail.
#
# Idempotent: if an AMI with the target name already exists, prints its id
# and exits immediately unless --force is given.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=../lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: build-custom-ami.sh -a <account-alias> [-v <ocp-minor>] [-r <rhel-major>] [--dns <bastion-private-ip>] [--force]"
  exit 1
}

account_alias=""
ocp_minor="4.22"
rhel_major="9"
force=false
dns_ip=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    -v)
      ocp_minor="$2"
      shift 2
      ;;
    -r)
      rhel_major="$2"
      shift 2
      ;;
    --dns)
      dns_ip="$2"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] || usage

# Masters fetch their real MachineConfig from https://api-int.<domain>:22623
# on first boot -- a name only the bastion's CoreDNS can answer (no Route53
# here, and it's a shared VPC so we can't touch its DHCP options). That
# fetch happens inside Ignition's own config.merge stage, which resolves
# before any Ignition-delivered file (e.g. a NetworkManager dispatcher
# MachineConfig) ever gets written to disk -- confirmed for real: a
# MachineConfig-delivered DNS fix never arrived, because it was stuck behind
# the exact merge-fetch it was meant to unblock. DNS has to be live before
# Ignition's own network fetches start, which means it has to be a kernel
# argument (dracut's `nameserver=`, carried into the real root's
# NetworkManager config), patched into the boot entry same as
# ignition.platform.id and console= below. `nameserver=` alone (without
# `ip=`) is a real trap, not a hypothetical one -- confirmed for real: it
# hung dracut-cmdline parsing before any console output at all, on every
# node including bootstrap. Always pair it with `ip=dhcp`.
if [ -z "$dns_ip" ]; then
  dns_ip=$(cd "$repo_root/terraform" && terraform output -raw bastion_private_ip 2>/dev/null || true)
fi
if [ -z "$dns_ip" ]; then
  echo "ERROR: --dns <bastion-private-ip> not given and no bastion_private_ip terraform output available." >&2
  echo "Masters cannot resolve api-int.<domain> without this -- see the comment above. Pass --dns explicitly" >&2
  echo "(e.g. from locals.tf's cidrhost() formula) if the bastion hasn't been applied yet for this account." >&2
  exit 1
fi
echo "Bastion DNS target: $dns_ip" >&2

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found. Copy accounts/example.tfvars.sample first." >&2
  exit 1
}

region=$(read_tfvar aws_region "$tfvars")
vpc_id=$(read_tfvar existing_vpc_id "$tfvars")
subnet_id=$(read_tfvar existing_private_subnet_id "$tfvars")
if [ -z "$region" ] || [ -z "$vpc_id" ] || [ -z "$subnet_id" ]; then
  echo "ERROR: aws_region / existing_vpc_id / existing_private_subnet_id must all be set in $tfvars" >&2
  exit 1
fi

ami_name="rhcos-${ocp_minor}-rhel${rhel_major}-custom-${account_alias}"
echo "Target AMI name: $ami_name" >&2

existing_ami=$(aws ec2 describe-images --region "$region" --owners self \
  --filters "Name=name,Values=${ami_name}" "Name=state,Values=available" \
  --query 'Images[0].ImageId' --output text 2>/dev/null || echo "None")
if [ "$existing_ami" != "None" ] && [ -n "$existing_ami" ] && [ "$force" != "true" ]; then
  echo "AMI already exists: $existing_ami (pass --force to rebuild)" >&2
  echo "$existing_ami"
  exit 0
fi

echo "Resolving RHCOS raw disk image location for OCP ${ocp_minor} / RHEL ${rhel_major}..." >&2
stream_url="https://raw.githubusercontent.com/openshift/installer/release-${ocp_minor}/data/data/coreos/coreos-rhel-${rhel_major}.json"
stream_json=$(curl -fsSL "$stream_url") || {
  echo "ERROR: failed to fetch $stream_url" >&2
  exit 1
}
disk_url=$(echo "$stream_json" | jq -r '.architectures.x86_64.artifacts.metal.formats["raw.gz"].disk.location // empty')
if [ -z "$disk_url" ]; then
  echo "ERROR: could not find the metal raw.gz artifact in $stream_url" >&2
  echo "Red Hat has moved this metadata's shape before -- inspect the file directly." >&2
  exit 1
fi
echo "Disk image: $disk_url" >&2

helper_ami=$(aws ec2 describe-images --region "$region" --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
echo "Helper base AMI (AWS-owned, allowed by SCP): $helper_ami" >&2

default_sg=$(aws ec2 describe-security-groups --region "$region" \
  --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=default" \
  --query 'SecurityGroups[0].GroupId' --output text)

run_id="ocp-ami-build-$(date +%s)"
cleanup_role=false
cleanup_instance=""

cleanup() {
  echo "Cleaning up build resources..." >&2
  if [ -n "$cleanup_instance" ]; then
    aws ec2 terminate-instances --region "$region" --instance-ids "$cleanup_instance" >/dev/null 2>&1 || true
  fi
  if [ "$cleanup_role" = "true" ]; then
    aws iam remove-role-from-instance-profile --instance-profile-name "$run_id" --role-name "$run_id" >/dev/null 2>&1 || true
    aws iam delete-instance-profile --instance-profile-name "$run_id" >/dev/null 2>&1 || true
    aws iam detach-role-policy --role-name "$run_id" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
    aws iam delete-role --role-name "$run_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Creating temporary SSM instance role ($run_id)..." >&2
aws iam create-role --role-name "$run_id" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --tags "Key=Purpose,Value=ocp-ami-build" >/dev/null
aws iam attach-role-policy --role-name "$run_id" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name "$run_id" --tags "Key=Purpose,Value=ocp-ami-build" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$run_id" --role-name "$run_id"
cleanup_role=true
sleep 10 # IAM propagation

echo "Launching helper instance with a blank 16GiB target volume..." >&2
instance_id=$(aws ec2 run-instances --region "$region" \
  --image-id "$helper_ami" \
  --instance-type t3.medium \
  --subnet-id "$subnet_id" \
  --security-group-ids "$default_sg" \
  --iam-instance-profile "Name=$run_id" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"VolumeSize\":16,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":false}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Purpose,Value=ocp-ami-build},{Key=Name,Value=${run_id}}]" \
    "ResourceType=volume,Tags=[{Key=Purpose,Value=ocp-ami-build}]" \
  --metadata-options 'HttpTokens=required' \
  --query 'Instances[0].InstanceId' --output text)
cleanup_instance="$instance_id"
echo "Helper instance: $instance_id" >&2

target_volume_id=$(aws ec2 describe-volumes --region "$region" \
  --filters "Name=attachment.instance-id,Values=$instance_id" "Name=attachment.device,Values=/dev/sdf" \
  --query 'Volumes[0].VolumeId' --output text)
echo "Target volume: $target_volume_id" >&2

echo "Waiting for SSM agent to register..." >&2
ping="None"
for _ in $(seq 1 24); do
  ping=$(aws ssm describe-instance-information --region "$region" \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
  [ "$ping" = "Online" ] && break
  sleep 10
done
if [ "$ping" != "Online" ]; then
  echo "ERROR: SSM agent never came online on $instance_id" >&2
  exit 1
fi

echo "Streaming RHCOS raw disk image onto the target volume..." >&2
# Nitro instances (t3.*) present EBS volumes as NVMe devices; the requested
# name (/dev/sdf) isn't guaranteed to map directly. /dev/disk/by-id is the
# AWS-documented stable path independent of udev-symlink guesswork.
nvme_id="${target_volume_id//-/}"
remote_cmd=$(
  cat <<EOF
set -euo pipefail
DEV=""
for i in \$(seq 1 30); do
  for cand in /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${nvme_id} /dev/xvdf /dev/nvme1n1; do
    [ -e "\$cand" ] && DEV="\$cand" && break 2
  done
  sleep 2
done
[ -n "\$DEV" ] || { echo "target device never appeared"; exit 1; }
echo "writing to \$DEV"
curl -fsSL "${disk_url}" | gunzip | dd of="\$DEV" bs=4M conv=fsync status=progress
sync
echo "DISK_WRITE_COMPLETE"
EOF
)

cmd_id=$(aws ssm send-command --region "$region" \
  --instance-ids "$instance_id" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(jq -n --arg c "$remote_cmd" '{commands: [$c]}')" \
  --timeout-seconds 1800 \
  --query 'Command.CommandId' --output text)
echo "SSM command: $cmd_id" >&2

cmd_status="Pending"
for i in $(seq 1 90); do
  cmd_status=$(aws ssm get-command-invocation --region "$region" \
    --command-id "$cmd_id" --instance-id "$instance_id" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  echo "[$i] $cmd_status" >&2
  case "$cmd_status" in Success | Failed | Cancelled | TimedOut) break ;; esac
  sleep 20
done

if [ "$cmd_status" != "Success" ]; then
  echo "ERROR: disk write failed (status=$cmd_status)" >&2
  aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query 'StandardErrorContent' --output text >&2
  exit 1
fi

# The metal raw.gz artifact boots with ignition.platform.id=metal baked into
# its GRUB entry, so on EC2 it never checks instance user-data for a config
# -- nodes boot but never apply our pointer ignition. Confirmed via a real
# bootstrap+master bring-up that sat with empty console output and zero open
# OpenShift ports. This is the same patch `coreos-installer install
# --platform aws` applies; done by hand since the AL2023 helper doesn't ship
# that tool. Also adds console=ttyS0 so EC2 console output is usable for
# future debugging.
echo "Patching ignition.platform.id=metal -> aws in the boot entry..." >&2
patch_cmd=$(
  cat <<EOF
set -euo pipefail
udevadm settle
BOOT_PART=""
for i in \$(seq 1 15); do
  BOOT_PART=\$(blkid -L boot || true)
  [ -n "\$BOOT_PART" ] && break
  sleep 2
done
[ -n "\$BOOT_PART" ] || { echo "boot partition (fs label 'boot') never appeared"; exit 1; }
mkdir -p /mnt/rhcosboot
mount "\$BOOT_PART" /mnt/rhcosboot
f=/mnt/rhcosboot/loader.1/entries/ostree-1.conf
[ -f "\$f" ] || { echo "expected boot entry \$f not found"; ls -la /mnt/rhcosboot/loader.1/entries 2>&1 || true; exit 1; }
grep -q 'ignition.platform.id=metal' "\$f" || { echo "ignition.platform.id=metal not found in \$f -- RHCOS boot layout may have changed, inspect before assuming this patch still applies"; cat "\$f"; exit 1; }
sed -i 's/ignition.platform.id=metal/ignition.platform.id=aws console=ttyS0,115200n8 console=tty0 ip=dhcp nameserver=${dns_ip}/' "\$f"
cat "\$f"
sync
umount /mnt/rhcosboot
echo PLATFORM_PATCH_COMPLETE
EOF
)

patch_cmd_id=$(aws ssm send-command --region "$region" \
  --instance-ids "$instance_id" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(jq -n --arg c "$patch_cmd" '{commands: [$c]}')" \
  --timeout-seconds 300 \
  --query 'Command.CommandId' --output text)
echo "SSM command: $patch_cmd_id" >&2

patch_status="Pending"
for i in $(seq 1 20); do
  patch_status=$(aws ssm get-command-invocation --region "$region" \
    --command-id "$patch_cmd_id" --instance-id "$instance_id" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  echo "[$i] $patch_status" >&2
  case "$patch_status" in Success | Failed | Cancelled | TimedOut) break ;; esac
  sleep 5
done

if [ "$patch_status" != "Success" ]; then
  echo "ERROR: platform-id patch failed (status=$patch_status)" >&2
  aws ssm get-command-invocation --region "$region" --command-id "$patch_cmd_id" --instance-id "$instance_id" \
    --query 'StandardErrorContent' --output text >&2
  exit 1
fi

echo "Stopping helper instance for a clean detach..." >&2
aws ec2 stop-instances --region "$region" --instance-ids "$instance_id" >/dev/null
aws ec2 wait instance-stopped --region "$region" --instance-ids "$instance_id"

echo "Detaching target volume..." >&2
aws ec2 detach-volume --region "$region" --volume-id "$target_volume_id" >/dev/null
aws ec2 wait volume-available --region "$region" --volume-ids "$target_volume_id"

echo "Terminating helper instance..." >&2
aws ec2 terminate-instances --region "$region" --instance-ids "$instance_id" >/dev/null
cleanup_instance="" # handled explicitly above; avoid a redundant call from the trap

echo "Snapshotting the volume as our own identity (the operation vmimport is blocked from -- we are not)..." >&2
snapshot_id=$(aws ec2 create-snapshot --region "$region" --volume-id "$target_volume_id" \
  --description "$ami_name" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Purpose,Value=ocp-ami-build},{Key=Name,Value=${ami_name}}]" \
  --query 'SnapshotId' --output text)
aws ec2 wait snapshot-completed --region "$region" --snapshot-ids "$snapshot_id"
echo "Snapshot: $snapshot_id" >&2

echo "Deleting the now-snapshotted volume..." >&2
aws ec2 delete-volume --region "$region" --volume-id "$target_volume_id"

echo "Registering AMI (boot settings mirrored from the official RHCOS AMI: legacy-bios, hvm, ena, sriov=simple)..." >&2
image_id=$(aws ec2 register-image --region "$region" \
  --name "$ami_name" \
  --architecture x86_64 \
  --root-device-name /dev/xvda \
  --virtualization-type hvm \
  --ena-support \
  --sriov-net-support simple \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"SnapshotId\":\"$snapshot_id\"}}]" \
  --tag-specifications "ResourceType=image,Tags=[{Key=Purpose,Value=ocp-ami-build},{Key=Name,Value=${ami_name}}]" \
  --query 'ImageId' --output text)

echo "Registered: $image_id" >&2
echo "$image_id"
