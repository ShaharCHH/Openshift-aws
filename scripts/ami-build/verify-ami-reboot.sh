#!/usr/bin/env bash
# Proves an RHCOS AMI still has networking AFTER a reboot, not just on first boot.
#
# WHY THIS EXISTS: build-custom-ami.sh ends at register-image and never boots what
# it built. That gap cost a full cluster. The AMI carries `ip=dhcp
# nameserver=<bastion>` kernel arguments so Ignition can resolve api-int inside the
# initramfs -- but on RHEL 9 those same arguments change NetworkManager's behaviour
# on the real root, and without a persistent connection profile every boot AFTER
# the first comes up with no address at all. First boot looks perfect; the cluster
# dies the moment the MCO reboots a node, which it does as routine maintenance.
#
# So first-boot success proves nothing. This script reboots and checks again --
# that second check is the entire point of the script.
#
# The probe runs FROM the bastion, over SSM, against the test instance's port 22.
# Deliberately not `aws ec2 get-console-output`: that API has been unreliable in
# this account all along (it showed nothing for an instance demonstrably alive at
# 500+ seconds uptime) and has already produced two wrong conclusions here. Port
# reachability is the only signal that has proven trustworthy.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=../lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: verify-ami-reboot.sh -a <account-alias> --ami <ami-id> [--boot-timeout <sec>]" >&2
  echo "  --ami is the output of build-custom-ami.sh (rhcos_ami_id is a -var, not a" >&2
  echo "  terraform output, so it cannot be discovered automatically)." >&2
  exit 1
}

account_alias=""
ami_id=""
boot_timeout=420
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --ami)
      ami_id="$2"
      shift 2
      ;;
    --boot-timeout)
      boot_timeout="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] && [ -n "$ami_id" ] || usage

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found." >&2
  exit 1
}
region=$(read_tfvar aws_region "$tfvars")
vpc_id=$(read_tfvar existing_vpc_id "$tfvars")
subnet_id=$(read_tfvar existing_private_subnet_id "$tfvars")
[ -n "$region" ] && [ -n "$vpc_id" ] && [ -n "$subnet_id" ] || {
  echo "ERROR: aws_region / existing_vpc_id / existing_private_subnet_id must be set in $tfvars" >&2
  exit 1
}

echo "Region:      $region" >&2
echo "AMI:         $ami_id" >&2

# The bastion is the probe origin: it already sits in the same subnet, already has
# an SSM agent, and is the one host guaranteed to be able to reach cluster nodes.
bastion_id=$(cd "$repo_root/terraform" && terraform output -raw bastion_instance_id 2>/dev/null || true)
[ -n "$bastion_id" ] || {
  echo "ERROR: no bastion_instance_id terraform output -- the bastion must be up to probe from." >&2
  exit 1
}
bastion_sg=$(aws ec2 describe-instances --region "$region" --instance-ids "$bastion_id" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
echo "Probing via bastion $bastion_id (sg $bastion_sg)" >&2

run_id="ocp-ami-reboot-test-$(date +%s)"
cleanup_instance=""
cleanup_sg=""

cleanup() {
  echo "Cleaning up test resources..." >&2
  if [ -n "$cleanup_instance" ]; then
    aws ec2 terminate-instances --region "$region" --instance-ids "$cleanup_instance" >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --region "$region" --instance-ids "$cleanup_instance" >/dev/null 2>&1 || true
  fi
  # The SG can only go once nothing references it, hence the wait above.
  if [ -n "$cleanup_sg" ]; then
    aws ec2 delete-security-group --region "$region" --group-id "$cleanup_sg" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Creating temporary security group..." >&2
cleanup_sg=$(aws ec2 create-security-group --region "$region" \
  --group-name "$run_id" \
  --description "temporary: RHCOS AMI reboot verification" \
  --vpc-id "$vpc_id" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Purpose,Value=ocp-ami-test},{Key=Name,Value=${run_id}}]" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --region "$region" \
  --group-id "$cleanup_sg" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$bastion_sg}]" >/dev/null

# Only the NetworkManager keyfile -- no cluster config, no MCS fetch. The point is
# to isolate "does this image keep its address across a reboot" from every other
# moving part in a cluster bring-up.
keyfile=$(sed "s/\${bastion_private_ip}/$(cd "$repo_root/terraform" && terraform output -raw bastion_private_ip)/" \
  "$repo_root/terraform/templates/node-network.nmconnection.tpl" | base64 | tr -d '\n')
user_data=$(printf '{"ignition":{"version":"3.2.0"},"storage":{"files":[{"path":"/etc/NetworkManager/system-connections/default-dhcp.nmconnection","mode":384,"overwrite":true,"contents":{"source":"data:text/plain;base64,%s"}}]}}' "$keyfile")

echo "Launching test instance from $ami_id..." >&2
cleanup_instance=$(aws ec2 run-instances --region "$region" \
  --image-id "$ami_id" \
  --instance-type t3.medium \
  --subnet-id "$subnet_id" \
  --security-group-ids "$cleanup_sg" \
  --user-data "$user_data" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Purpose,Value=ocp-ami-test},{Key=Name,Value=${run_id}}]" \
  --metadata-options 'HttpTokens=required' \
  --query 'Instances[0].InstanceId' --output text)
target_ip=$(aws ec2 describe-instances --region "$region" --instance-ids "$cleanup_instance" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "Test instance: $cleanup_instance ($target_ip)" >&2

# Polls port 22 from the bastion. RHCOS runs sshd by default, so an open 22 means
# the guest booted far enough to configure its interface -- which is all we are
# asking. Returns 0 as soon as it opens, 1 if the deadline passes.
wait_for_port() {
  local label="$1" deadline=$((SECONDS + boot_timeout)) out=""
  echo "  waiting for $target_ip:22 ($label, up to ${boot_timeout}s)..." >&2
  while [ "$SECONDS" -lt "$deadline" ]; do
    cid=$(aws ssm send-command --region "$region" --instance-ids "$bastion_id" \
      --document-name "AWS-RunShellScript" \
      --parameters "commands=[\"timeout 3 bash -c '</dev/tcp/$target_ip/22' 2>/dev/null && echo REACHABLE || echo no\"]" \
      --query 'Command.CommandId' --output text 2>/dev/null || echo "")
    if [ -n "$cid" ]; then
      sleep 6
      out=$(aws ssm get-command-invocation --region "$region" --command-id "$cid" \
        --instance-id "$bastion_id" --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
      case "$out" in
        *REACHABLE*)
          echo "  $label: REACHABLE after $((SECONDS))s" >&2
          return 0
          ;;
      esac
    fi
    sleep 10
  done
  echo "  $label: NEVER REACHABLE within ${boot_timeout}s" >&2
  return 1
}

if ! wait_for_port "first boot"; then
  echo >&2
  echo "FAIL: the instance never came up even on its first boot. That is a different" >&2
  echo "problem from the one this script tests -- check the AMI itself before reading" >&2
  echo "anything into the reboot behaviour." >&2
  exit 1
fi

echo "Rebooting -- this is the actual test..." >&2
aws ec2 reboot-instances --region "$region" --instance-ids "$cleanup_instance"
sleep 30 # let it actually go down before we start believing an open port

if ! wait_for_port "after reboot"; then
  echo >&2
  echo "FAIL: the instance came up on first boot but not after a reboot." >&2
  echo "This is exactly the failure that killed the cluster: the node loses its" >&2
  echo "address on every boot after the first, and the MCO reboots nodes routinely." >&2
  echo "Check that the NetworkManager keyfile actually landed -- serial console at" >&2
  echo "ec2-serial-console.${region}.api.aws (push the SSH key immediately before" >&2
  echo "connecting; it is valid for about 60 seconds)." >&2
  exit 1
fi

echo >&2
echo "PASS: reachable on first boot and again after a reboot. This AMI survives the" >&2
echo "MCO's config rollout." >&2
