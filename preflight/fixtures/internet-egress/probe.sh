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
  --parameters 'commands=["curl -sS -m 8 -o /dev/null -w \"HTTP %{http_code}\" https://mirror.openshift.com/ || echo FAILED"]' \
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

# A curl HTTP response code (even a redirect, e.g. 301/302) proves egress
# works; "FAILED" (from the command's own fallback) means it doesn't.
if [ "$status" = "Success" ] && echo "$detail" | grep -qE '^HTTP [0-9]+'; then
  printf '{"status":"Success","detail":%s}\n' "$(printf '%s' "$detail" | jq -Rs .)"
else
  printf '{"status":"Failed","detail":%s}\n' "$(printf '%s' "$detail" | jq -Rs .)"
fi
