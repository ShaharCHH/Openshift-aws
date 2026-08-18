#!/usr/bin/env bash
# terraform `external` data source contract: read (and ignore) a JSON object
# on stdin, write exactly one JSON object of string->string to stdout.
set -euo pipefail

instance_id="$1"
timeout_seconds="${2:-240}"
deadline=$((SECONDS + timeout_seconds))

registered=false
while [ "$SECONDS" -lt "$deadline" ]; do
  state=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${instance_id}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
  if [ "$state" = "Online" ]; then
    registered=true
    break
  fi
  sleep 5
done

if [ "$registered" != "true" ]; then
  printf '{"status":"Failed","detail":"ssm agent never registered Online within %ss"}\n' "$timeout_seconds"
  exit 0
fi

command_id=$(aws ssm send-command \
  --instance-ids "$instance_id" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["echo preflight-ssm-ok"]' \
  --query 'Command.CommandId' --output text)

status="InProgress"
while [ "$SECONDS" -lt "$deadline" ]; do
  status=$(aws ssm get-command-invocation \
    --command-id "$command_id" --instance-id "$instance_id" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  case "$status" in
    Success | Failed | Cancelled | TimedOut) break ;;
  esac
  sleep 5
done

detail=$(aws ssm get-command-invocation \
  --command-id "$command_id" --instance-id "$instance_id" \
  --query 'StandardOutputContent' --output text 2>/dev/null || echo "")

printf '{"status":"%s","detail":%s}\n' "$status" "$(printf '%s' "$detail" | jq -Rs .)"
