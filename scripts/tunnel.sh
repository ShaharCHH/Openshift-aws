#!/usr/bin/env bash
# Opens an SSM port-forward from this machine to the bastion, and keeps it open.
#
# WHY THIS EXISTS: nothing in this deployment has a public endpoint -- no EIP,
# no Route 53, no ELB (docs/scp-blockers.md rows 1, 3 and 4) -- so the bastion's
# HAProxy is the only route to the cluster's API and ingress, and SSM Session
# Manager is the only route to the bastion. Every oc call and every browser tab
# starts here.
#
# The raw `aws ssm start-session` command this wraps is still in
# docs/runbook.md and still works. What this adds is the part that bites in
# daily use: the session ends on its own idle timeout, and it ends CLEANLY --
# exit 0, no error, nothing on screen -- so nothing looks broken until the next
# oc call fails with `connection refused` to 127.0.0.1:6443. The loop below
# reconnects and says so.
#
# Reads everything it needs from accounts/<alias>.tfvars, so unlike the runbook
# command it needs no terraform state and no particular working directory --
# same as hibernate.sh/wake.sh.
set -uo pipefail # NOT -e: start-session returning non-zero is this loop's
                 # normal input, not a reason to abort.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: tunnel.sh -a <account-alias> [--api | --console]"
  echo
  echo "  --api      (default) forwards 6443 -- oc/kubectl and the API"
  echo "  --console  forwards 443 -- the web console; needs sudo -E, see below"
  echo
  echo "One session forwards one port, so run a second terminal for --console."
  exit 1
}

account_alias=""
mode="api"
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --api)
      mode="api"
      shift
      ;;
    --console)
      mode="console"
      shift
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
cluster_name=$(read_tfvar cluster_name "$tfvars")
base_domain=$(read_tfvar base_domain "$tfvars")
if [ -z "$region" ] || [ -z "$cluster_name" ] || [ -z "$base_domain" ]; then
  echo "ERROR: aws_region / cluster_name / base_domain must all be set in $tfvars" >&2
  exit 1
fi

case "$mode" in
  api)
    port=6443
    # `api.` only, deliberately -- NOT api-int. The installer's kubeconfig
    # points at https://api.<cluster>.<domain>:6443 and nothing on the
    # operator's machine ever resolves the internal name: api-int is what
    # CLUSTER NODES use (MCS on 22623, resolved by the bastion's CoreDNS and
    # its own /etc/hosts, both set up by the bastion userdata). Listing it here
    # produced a warning on every run for an entry nobody needs.
    hostnames=("api.${cluster_name}.${base_domain}")
    ;;
  console)
    # 443 specifically, not a convenient high port: the console redirects to
    # the OAuth server by canonical hostname with no port in it, so any other
    # local port breaks the login flow right after the first page loads.
    port=443
    hostnames=("console-openshift-console.apps.${cluster_name}.${base_domain}" \
      "oauth-openshift.apps.${cluster_name}.${base_domain}")
    ;;
esac

fmt_duration() {
  if [ "$1" -ge 60 ]; then
    echo "$(($1 / 60))m$(($1 % 60))s"
  else
    echo "$1s"
  fi
}

# --console needs root to bind 443, and `sudo -E` deliberately keeps HOME
# pointing at the invoking user -- that is what lets the aws CLI still find
# AWS_PROFILE and the SSO cache. The cost is that anything the CLI writes there
# while running as root (a refreshed SSO token, an assumed-role cache entry) is
# left ROOT-OWNED in the user's own ~/.aws.
#
# That breaks the NEXT ordinary, non-sudo login rather than this run, so the
# cause and the symptom are hours apart:
#
#   aws: [ERROR]: [Errno 13] Permission denied:
#     '/Users/<you>/.aws/sso/cache/706aa66a...json'
#
# The filename is a hash of the start URL, so it names nothing you can act on.
# Hit for real on this machine (a root-owned token from 19 Aug 2026 blocked a
# login on 21 Aug). Hand anything root created back to the invoking user.
restore_aws_ownership() {
  [ -n "${SUDO_USER:-}" ] || return 0
  [ -d "${HOME:-}/.aws" ] || return 0
  find "$HOME/.aws" -user 0 -exec chown "$SUDO_USER" {} + 2>/dev/null || true
}

# Registered before the first aws call, and on EXIT rather than only at the end,
# so it still runs when a preflight check bails out or the loop gives up.
trap restore_aws_ownership EXIT

# ---- preflight: each failure names its own fix ----

command -v session-manager-plugin >/dev/null 2>&1 || {
  echo "ERROR: session-manager-plugin not found on PATH." >&2
  echo "start-session cannot forward a port without it, and its own error does not name it." >&2
  echo "https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
  exit 1
}

# Ports below 1024 need root. Caught here rather than left to fail on the bind,
# because -E is the part that is easy to miss: plain sudo resets the
# environment, hiding AWS_PROFILE and the SSO cache from the aws CLI, which
# then fails as though the credentials themselves were the problem.
if [ "$port" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: local port $port is privileged and this shell is not root." >&2
  echo "Re-run as:  sudo -E $0 -a $account_alias --$mode" >&2
  echo "(-E preserves AWS_PROFILE and your SSO cache -- plain sudo will not.)" >&2
  exit 1
fi

holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
if [ -n "$holder" ]; then
  echo "ERROR: local port $port is already bound by PID $holder ($(ps -p "$holder" -o comm= 2>/dev/null))." >&2
  echo "A tunnel left running in another terminal is the usual reason." >&2
  exit 1
fi

# The tunnel binds 127.0.0.1, but the kubeconfig and the browser both use the
# cluster's real names -- so without these entries it is up and unreachable.
# Warned about rather than written: /etc/hosts is the operator's file, not this
# script's. Note the console needs BOTH names; CoreDNS answers *.apps with a
# wildcard, /etc/hosts has no such thing.
missing_lines=""
missing_flat=""
for name in "${hostnames[@]}"; do
  if ! awk -v n="$name" '!/^[[:space:]]*#/ && $1 == "127.0.0.1" {
         for (i = 2; i <= NF; i++) if ($i == n) found = 1
       } END { exit !found }' /etc/hosts; then
    missing_lines="${missing_lines}  ${name}"$'\n'
    missing_flat="${missing_flat}${missing_flat:+ }${name}"
  fi
done
if [ -n "$missing_flat" ]; then
  echo "WARNING: these names do not resolve to 127.0.0.1 in /etc/hosts:" >&2
  printf '%s' "$missing_lines" >&2
  echo "         The tunnel will be up, but nothing will reach it by name. Add them with:" >&2
  # Only the missing ones -- re-adding a name that is already mapped works, but
  # leaves a duplicate entry behind for someone to puzzle over later.
  echo "           echo '127.0.0.1  ${missing_flat}' | sudo tee -a /etc/hosts" >&2
  echo >&2
fi

# The other half of restore_aws_ownership: catch the damage an EARLIER sudo run
# left behind, since that is what actually breaks `aws sso login` and the error
# it produces names only a hash.
if [ "$(id -u)" -ne 0 ] && [ -d "${HOME:-}/.aws" ]; then
  root_owned=$(find "$HOME/.aws" -user 0 2>/dev/null)
  if [ -n "$root_owned" ]; then
    echo "WARNING: root-owned files in your ~/.aws, left by an earlier sudo run:" >&2
    while IFS= read -r f; do
      echo "           $f" >&2
    done <<<"$root_owned"
    echo "         These make 'aws sso login' fail with Permission denied on its own" >&2
    echo "         cache. Clear them (the directories are yours, so no sudo needed):" >&2
    echo "           find ~/.aws -user 0 -delete" >&2
    echo >&2
  fi
fi

# Checked explicitly, and before the lookup below, because an expired SSO
# session makes describe-instances return NOTHING rather than fail -- which
# reads identically to "the bastion is stopped" and sends you off to wake.sh
# for a problem that is really just `aws sso login`.
#
# The CLI's own message is kept and shown rather than replaced with a guess:
# "Token for <sso-session> does not exist" (never logged in), "Your session has
# expired" (log in again) and a profile typo all land here, and they need
# different fixes. Swallowing them costs a diagnostic round-trip.
if ! sts_err=$(aws sts get-caller-identity --region "$region" 2>&1 >/dev/null); then
  echo "ERROR: no valid AWS credentials for this shell." >&2
  # The CLI pads its own output with blank lines; strip them so the reason
  # reads as part of this error rather than a stray paragraph.
  printf '%s\n' "$sts_err" | grep -v '^[[:space:]]*$' | sed 's/^/  /' >&2
  echo "  aws sso login --profile ${AWS_PROFILE:-<your-profile>}" >&2
  exit 1
fi

# Same tag filter wake.sh uses. Project/AccountAlias come from the provider's
# default_tags, so this needs no terraform state.
bastion_id=$(aws ec2 describe-instances --region "$region" \
  --filters "Name=tag:AccountAlias,Values=${account_alias}" \
  "Name=tag:Project,Values=openshift-upi" \
  "Name=tag:Name,Values=*-bastion" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -z "$bastion_id" ]; then
  echo "ERROR: no running bastion found for account-alias=${account_alias} in ${region}." >&2
  echo "If the cluster is hibernated:  ./scripts/wake.sh -a ${account_alias}" >&2
  exit 1
fi
if [ "$(echo "$bastion_id" | wc -w)" -gt 1 ]; then
  echo "ERROR: more than one running bastion matched: $bastion_id" >&2
  exit 1
fi

ping_status=$(aws ssm describe-instance-information --region "$region" \
  --filters "Key=InstanceIds,Values=${bastion_id}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
if [ "$ping_status" != "Online" ]; then
  echo "ERROR: bastion $bastion_id is running but its SSM agent is not Online (status: ${ping_status})." >&2
  echo "The agent needs 30-90s after a start to register -- if it was just woken, wait and retry." >&2
  exit 1
fi

# ---- the tunnel, supervised ----

stopping=false
session_pid=""

# Kills the session as well as setting the flag, and kills the CHILD first.
# `aws` spawns session-manager-plugin as a subprocess, and the plugin is what
# actually holds the local port -- killing only the parent orphans it, leaving
# the port bound after this script has exited.
stop_session() {
  stopping=true
  if [ -n "$session_pid" ]; then
    pkill -TERM -P "$session_pid" 2>/dev/null
    kill -TERM "$session_pid" 2>/dev/null
  fi
}
trap stop_session INT TERM

echo "bastion ${bastion_id}  SSM Online"
echo "tunnel  127.0.0.1:${port} -> bastion:${port}  (${mode})"
echo "Ctrl-C to close."

fast_failures=0
while true; do
  started=$SECONDS
  # Backgrounded and waited on, rather than run in the foreground, because bash
  # defers a trap until the current foreground command finishes.
  #
  # Ctrl-C in a terminal hides this: it signals the whole foreground process
  # group, so `aws` dies on its own and the trap then runs. But a signal aimed
  # at THIS process alone -- `kill <pid>`, a supervisor's SIGTERM -- left the
  # script sitting there with the port still bound, because `aws` never got it
  # and the trap stayed queued behind it. Confirmed for real, and fixed by this:
  # `wait` is interruptible, so the trap runs immediately either way.
  aws ssm start-session --region "$region" --target "$bastion_id" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"${port}\"],\"localPortNumber\":[\"${port}\"]}" &
  session_pid=$!
  wait "$session_pid"
  rc=$?
  wait "$session_pid" 2>/dev/null # reap it if the trap did the killing
  session_pid=""
  ran=$((SECONDS - started))

  if [ "$stopping" = "true" ]; then
    echo
    echo "tunnel closed."
    exit 0
  fi

  echo "[$(date +%H:%M:%S)] session ended after $(fmt_duration "$ran") (exit ${rc}) -- reconnecting"

  # A session that ran for a while and then ended is the documented idle
  # timeout: it exits 0 with nothing on screen, which is the whole reason this
  # loop exists. Reconnect immediately.
  #
  # A session that dies within seconds is a real fault -- expired SSO
  # credentials being the usual one -- and reconnecting just spins. Allow three
  # so a genuine blip still self-heals, then stop and leave the last error
  # visible rather than burying it under retries.
  if [ "$ran" -lt 10 ]; then
    fast_failures=$((fast_failures + 1))
    if [ "$fast_failures" -ge 3 ]; then
      echo "ERROR: ${fast_failures} sessions in a row died within seconds (last exit ${rc})." >&2
      echo "That is not an idle timeout. Check 'aws sts get-caller-identity' and the bastion's SSM status." >&2
      exit 1
    fi
    sleep 5
  else
    fast_failures=0
  fi
done
