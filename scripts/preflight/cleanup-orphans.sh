#!/usr/bin/env bash
# Tag-based sweep backstop: deletes anything still tagged
# Purpose=ocp-preflight or ocp-preflight-scp-probe. Runs unconditionally
# from run-all.sh's EXIT trap, so it's the safety net for the case where
# `terraform test`'s own destroy, or scp-probes.sh's inline cleanup, was
# itself interrupted (OOM, network partition, Ctrl-C) before finishing.
set -uo pipefail

region="${1:?usage: cleanup-orphans.sh <region>}"

echo "Sweeping for orphaned ocp-preflight-tagged resources in ${region}..."

resources=$(aws resourcegroupstaggingapi get-resources \
  --region "$region" \
  --tag-filters "Key=Purpose,Values=ocp-preflight,ocp-preflight-scp-probe" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)

if [ -z "$resources" ]; then
  echo "Nothing found. Clean."
  exit 0
fi

for arn in $resources; do
  echo "Orphan found: $arn"
  case "$arn" in
    *:ec2:*:instance/*)
      id="${arn##*/}"
      echo "  terminating instance $id"
      aws ec2 terminate-instances --region "$region" --instance-ids "$id" >/dev/null 2>&1
      ;;
    *:ec2:*:network-interface/*)
      id="${arn##*/}"
      echo "  deleting eni $id"
      aws ec2 delete-network-interface --region "$region" --network-interface-id "$id" 2>/dev/null \
        || echo "    (still attached, skip — will retry next run)"
      ;;
    *:ec2:*:security-group/*)
      id="${arn##*/}"
      echo "  deleting security group $id"
      aws ec2 delete-security-group --region "$region" --group-id "$id" 2>/dev/null \
        || echo "    (still in use, skip — will retry next run)"
      ;;
    *:ec2:*:vpc-endpoint/*)
      id="${arn##*/}"
      echo "  deleting vpc endpoint $id"
      aws ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids "$id" >/dev/null 2>&1
      ;;
    *:ec2:*:snapshot/*)
      id="${arn##*/}"
      echo "  deleting snapshot $id"
      # A snapshot involved in an in-progress copy can't be deleted yet —
      # give it a few short retries rather than giving up immediately.
      for _ in 1 2 3 4 5; do
        aws ec2 delete-snapshot --region "$region" --snapshot-id "$id" >/dev/null 2>&1 && break
        sleep 5
      done
      ;;
    *:ec2:*:volume/*)
      id="${arn##*/}"
      echo "  deleting volume $id"
      aws ec2 delete-volume --region "$region" --volume-id "$id" 2>/dev/null \
        || echo "    (still in use, skip — will retry next run)"
      ;;
    *:s3:::*)
      bucket="${arn#arn:aws:s3:::}"
      echo "  emptying + deleting bucket $bucket"
      aws s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
      aws s3api delete-bucket --bucket "$bucket" --region "$region" 2>/dev/null \
        || echo "    (delete failed, check manually)"
      ;;
    *:iam::*:role/*)
      name="${arn##*/}"
      echo "  detaching + deleting role $name"
      for policy in $(aws iam list-attached-role-policies --role-name "$name" \
        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$name" --policy-arn "$policy" 2>/dev/null
      done
      aws iam delete-role --role-name "$name" 2>/dev/null \
        || echo "    (delete failed, may still be referenced by an instance profile)"
      ;;
    *:iam::*:instance-profile/*)
      name="${arn##*/}"
      role=$(aws iam get-instance-profile --instance-profile-name "$name" \
        --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || echo "")
      if [ -n "$role" ] && [ "$role" != "None" ]; then
        aws iam remove-role-from-instance-profile --instance-profile-name "$name" --role-name "$role" 2>/dev/null
      fi
      echo "  deleting instance profile $name"
      aws iam delete-instance-profile --instance-profile-name "$name" 2>/dev/null || true
      ;;
    *:iam::*:user/*)
      name="${arn##*/}"
      echo "  deleting iam user $name"
      aws iam delete-user --user-name "$name" 2>/dev/null \
        || echo "    (delete failed, may still have attached policies/keys -- check manually)"
      ;;
    *:iam::*:oidc-provider/*)
      echo "  deleting oidc provider $arn"
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" 2>/dev/null
      ;;
    *:elasticfilesystem:*:file-system/*)
      id="${arn##*/}"
      echo "  deleting efs filesystem $id"
      # A mount target still attached blocks delete-file-system; the EFS
      # preflight canary doesn't leave one behind, but retry briefly in case
      # something else does.
      for _ in 1 2 3 4 5; do
        aws efs delete-file-system --region "$region" --file-system-id "$id" >/dev/null 2>&1 && break
        sleep 5
      done
      ;;
    *)
      echo "  (no cleanup handler for this resource type, skipping: $arn)"
      ;;
  esac
done
