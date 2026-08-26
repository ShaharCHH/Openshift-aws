#!/usr/bin/env bash
# One-time setup for the storage design's export root: creates /openshift on
# the cluster's EFS filesystem, mode 1777, so nfs-subdir-external-provisioner
# (manifests/storage/nfs-provisioner.yaml) can create per-PVC subdirectories
# under it.
#
# WHY THIS EXISTS: a fresh EFS filesystem's root is root:root 755. The
# provisioner pod runs as an arbitrary non-root UID (OpenShift's
# restricted-v2 SCC), so it cannot create anything there -- that's the whole
# reason the design uses a pre-created 1777 subdirectory rather than the
# filesystem root itself. Using `/` instead doesn't avoid the problem, it
# just makes the entire filesystem world-writable. Either way, SOMETHING
# with root has to touch EFS once. Nothing inside the cluster can: no pod
# can hold an AWS credential (docs/architecture.md), and even root inside a
# pod has no path to a privileged NFS mount.
#
# The bastion does it instead, over SSM -- it's already the utility box for
# this deployment (DNS, HAProxy, ignition server, SSM entry point), and it
# works before any cluster node exists. This was previously done by hand on
# this cluster and recorded nowhere; that gap is what this script closes.
# See terraform/main.tf's module "efs" for the bastion->EFS security-group
# rule this depends on, and terraform/templates/bastion-userdata.sh.tpl for
# nfs-utils -- though userdata only runs at first boot, so this script also
# installs the package itself in case the bastion predates that change.
#
# Idempotent: checks the directory's owner/mode before touching anything, and
# reports which case it hit rather than assuming. Safe to re-run.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../scripts/lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: prepare-efs-root.sh -a <account-alias>" >&2
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

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found." >&2
  exit 1
}

region=$(read_tfvar aws_region "$tfvars")
[ -n "$region" ] || {
  echo "ERROR: aws_region not set in $tfvars" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq not found on PATH." >&2
  exit 1
}

# Tag-based, like every other day-2 script -- no terraform state, no cwd
# requirement.
bastion_id=$(aws ec2 describe-instances --region "$region" \
  --filters "Name=tag:AccountAlias,Values=${account_alias}" "Name=tag:Name,Values=*-bastion" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$bastion_id" ] || {
  echo "ERROR: no running bastion found for account-alias=${account_alias}." >&2
  echo "Is it up? Try ./scripts/wake.sh -a ${account_alias} first." >&2
  exit 1
}
echo "Bastion: $bastion_id" >&2

# The EFS filesystem is default-tagged the same way every resource in this
# deployment is (terraform/providers.tf's default_tags) -- discover it the
# same tag-based way rather than requiring terraform state.
fs_arn=$(aws resourcegroupstaggingapi get-resources --region "$region" \
  --tag-filters "Key=AccountAlias,Values=${account_alias}" "Key=Project,Values=openshift-upi" \
  --resource-type-filters "elasticfilesystem:file-system" \
  --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || echo "None")
if [ -z "$fs_arn" ] || [ "$fs_arn" = "None" ]; then
  echo "ERROR: no EFS filesystem found for account-alias=${account_alias}." >&2
  echo "Has 'terraform apply' created module.efs yet?" >&2
  exit 1
fi
fs_id="${fs_arn##*/}"
# Deterministic format (confirmed against terraform/modules/efs/outputs.tf's
# dns_name output) -- constructing it avoids an extra describe call.
efs_dns="${fs_id}.efs.${region}.amazonaws.com"
echo "EFS filesystem: $fs_id ($efs_dns)" >&2

remote_cmd=$(
  cat <<EOF
set -euo pipefail
rpm -q nfs-utils >/dev/null 2>&1 || dnf install -y nfs-utils
mkdir -p /mnt/efs-prepare-root
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \\
  ${efs_dns}:/ /mnt/efs-prepare-root
current=\$(stat -c '%a %U:%G' /mnt/efs-prepare-root/openshift 2>/dev/null || echo "MISSING")
if [ "\$current" = "1777 root:root" ]; then
  echo "ALREADY_CORRECT"
else
  mkdir -p /mnt/efs-prepare-root/openshift
  chmod 1777 /mnt/efs-prepare-root/openshift
  chown root:root /mnt/efs-prepare-root/openshift
  echo "CREATED (was: \$current)"
fi
stat -c '%a %U:%G %n' /mnt/efs-prepare-root/openshift
umount /mnt/efs-prepare-root
echo PREPARE_EFS_ROOT_COMPLETE
EOF
)

echo "Running over SSM..." >&2
cmd_id=$(aws ssm send-command --region "$region" \
  --instance-ids "$bastion_id" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(jq -n --arg c "$remote_cmd" '{commands: [$c]}')" \
  --timeout-seconds 120 \
  --query 'Command.CommandId' --output text)

status="Pending"
for _ in $(seq 1 24); do
  status=$(aws ssm get-command-invocation --region "$region" \
    --command-id "$cmd_id" --instance-id "$bastion_id" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  case "$status" in Success | Failed | Cancelled | TimedOut) break ;; esac
  sleep 5
done

stdout=$(aws ssm get-command-invocation --region "$region" \
  --command-id "$cmd_id" --instance-id "$bastion_id" \
  --query 'StandardOutputContent' --output text 2>/dev/null || echo "")

if [ "$status" != "Success" ]; then
  echo "ERROR: SSM command $cmd_id finished with status=$status" >&2
  aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$bastion_id" \
    --query 'StandardErrorContent' --output text >&2
  exit 1
fi

echo "$stdout"
case "$stdout" in
  *ALREADY_CORRECT*)
    echo "OK: /openshift already existed with the correct owner/mode -- nothing changed." >&2
    ;;
  *CREATED*)
    echo "OK: /openshift created (mode 1777, root:root)." >&2
    ;;
  *)
    echo "WARNING: command succeeded but output didn't match either expected case -- inspect above." >&2
    ;;
esac
