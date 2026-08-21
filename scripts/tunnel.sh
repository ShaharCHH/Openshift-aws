#!/usr/bin/env bash
# Opens SSM port-forwards from this machine to the bastion, and keeps them open.
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
# oc call fails with `connection refused` to 127.0.0.1:6443. The loops below
# reconnect and say so.
#
# One SSM session forwards exactly one port, which is a property of
# AWS-StartPortForwardingSession and not something this script can change. It
# can however supervise several at once, so --api --console is a single command
# rather than two terminals.
#
# Reads everything it needs from accounts/<alias>.tfvars, so unlike the runbook
# command it needs no terraform state and no particular working directory --
# same as hibernate.sh/wake.sh.
#
# Targets bash 3.2, which is what macOS ships and what `/usr/bin/env bash`
# resolves to here. No `wait -n` (4.3+) and no associative arrays (4.0+) -- see
# the parallel arrays below and the SIGUSR1 handshake at the bottom.
set -uo pipefail # NOT -e: start-session returning non-zero is these loops'
                 # normal input, not a reason to abort.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: tunnel.sh -a <account-alias> [--api] [--console] [--all] [--profile <aws-profile>]"
  echo
  echo "  --api      forwards 6443 -- oc/kubectl and the API (the default)"
  echo "  --console  forwards 443 -- the web console; needs sudo, see below"
  echo "  --all      both of the above, in one command"
  echo "  --profile  AWS profile to use; defaults to \$AWS_PROFILE"
  echo
  echo "--api and --console combine: '--api --console' forwards both at once."
  echo
  echo "Anything including --console binds a privileged port, so it needs sudo."
  echo "Pass --profile there rather than relying on the environment:"
  echo "  sudo -E ./scripts/tunnel.sh -a <alias> --all --profile <aws-profile>"
  exit 1
}

account_alias=""
profile=""
want_api=false
want_console=false
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    # Additive, not exclusive. These used to assign a single `mode`, so
    # `--console --api` silently forwarded only the API port -- the last flag
    # won and nothing said so. Booleans also make a repeated flag a no-op.
    --api)
      want_api=true
      shift
      ;;
    --console)
      want_console=true
      shift
      ;;
    --all)
      want_api=true
      want_console=true
      shift
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] || usage

# Default to the API alone, so ordinary day-to-day use never needs sudo.
if [ "$want_api" = false ] && [ "$want_console" = false ]; then
  want_api=true
fi

# Set explicitly rather than inherited, because inheriting is exactly what
# fails under sudo. `sudo -E` is documented as preserving the environment, but
# it does not reliably deliver AWS_PROFILE: the sudoers policy may strip it,
# and a fresh terminal opened just to run the sudo command never had it
# exported in the first place. Either way the aws CLI silently falls back to
# the [default] profile, and you get "Your session has expired" for a session
# you just refreshed -- the expired one belongs to a profile you never meant
# to use. Hit for real on 21 Aug 2026.
if [ -n "$profile" ]; then
  export AWS_PROFILE="$profile"
fi

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

# ---- what we are forwarding ----
#
# Parallel indexed arrays rather than one associative array, for bash 3.2.
# tunnel_hosts holds a space-separated name list per tunnel; hostnames contain
# no spaces, so that encoding is safe.
tunnel_labels=()
tunnel_ports=()
tunnel_hosts=()
flags="" # echoed back in the sudo hint, so it reproduces the full request

if [ "$want_api" = true ]; then
  tunnel_labels+=("api")
  tunnel_ports+=(6443)
  # `api.` only, deliberately -- NOT api-int. The installer's kubeconfig points
  # at https://api.<cluster>.<domain>:6443 and nothing on the operator's machine
  # ever resolves the internal name: api-int is what CLUSTER NODES use (MCS on
  # 22623, resolved by the bastion's CoreDNS and its own /etc/hosts, both set up
  # by the bastion userdata). Listing it here produced a warning on every run
  # for an entry nobody needs.
  tunnel_hosts+=("api.${cluster_name}.${base_domain}")
  flags="$flags --api"
fi
if [ "$want_console" = true ]; then
  tunnel_labels+=("console")
  # 443 specifically, not a convenient high port: the console redirects to the
  # OAuth server by canonical hostname with no port in it, so any other local
  # port breaks the login flow right after the first page loads.
  tunnel_ports+=(443)
  # Two names, not one, for that same reason -- CoreDNS answers *.apps with a
  # wildcard and /etc/hosts has no such thing, so the console loads and then
  # login fails on an unresolvable name.
  tunnel_hosts+=("console-openshift-console.apps.${cluster_name}.${base_domain} oauth-openshift.apps.${cluster_name}.${base_domain}")
  flags="$flags --console"
fi

# Pad labels so the prefixed output lines up when two tunnels share a terminal.
label_width=0
for label in "${tunnel_labels[@]}"; do
  [ ${#label} -gt "$label_width" ] && label_width=${#label}
done

fmt_duration() {
  if [ "$1" -ge 60 ]; then
    echo "$(($1 / 60))m$(($1 % 60))s"
  else
    echo "$1s"
  fi
}

# --console needs root to bind 443, and `sudo -E` deliberately keeps HOME
# pointing at the invoking user -- that is what lets the aws CLI find ~/.aws at
# all. The cost is that anything the CLI writes there while running as root (a
# refreshed SSO token, an assumed-role cache entry) is left ROOT-OWNED in the
# user's own ~/.aws.
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
# shellcheck disable=SC2329  # invoked via the EXIT trap, through cleanup_exit
restore_aws_ownership() {
  [ -n "${SUDO_USER:-}" ] || return 0
  [ -d "${HOME:-}/.aws" ] || return 0
  find "$HOME/.aws" -user 0 -exec chown "$SUDO_USER" {} + 2>/dev/null || true
}

# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup_exit() {
  restore_aws_ownership
  [ -n "${statedir:-}" ] && rm -rf "$statedir"
}

# Registered before the first aws call, and on EXIT rather than only at the end,
# so it still runs when a preflight check bails out or a tunnel gives up.
trap cleanup_exit EXIT

# ---- preflight: each failure names its own fix ----

command -v session-manager-plugin >/dev/null 2>&1 || {
  echo "ERROR: session-manager-plugin not found on PATH." >&2
  echo "start-session cannot forward a port without it, and its own error does not name it." >&2
  echo "https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
  exit 1
}

# Ports below 1024 need root. Caught here rather than left to fail on the bind.
needs_root=false
for port in "${tunnel_ports[@]}"; do
  [ "$port" -lt 1024 ] && needs_root=true
done
if [ "$needs_root" = true ] && [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: this needs a privileged local port (443) and this shell is not root." >&2
  echo "Re-run as:" >&2
  echo "  sudo -E $0 -a ${account_alias}${flags} --profile ${AWS_PROFILE:-<aws-profile>}" >&2
  echo >&2
  echo "  -E keeps HOME pointing at your home, so the aws CLI can still find" >&2
  echo "  ~/.aws. --profile is separate and matters just as much: sudo does NOT" >&2
  echo "  reliably carry AWS_PROFILE through even with -E, and the CLI then falls" >&2
  echo "  back to [default] and reports THAT profile's expiry -- which reads as" >&2
  echo "  'you are not logged in' when you are." >&2
  exit 1
fi

# Two checks, not one, and the second is the one that matters here.
#
# `lsof` names the holding PID, which is what you actually want -- but run
# unprivileged it CANNOT SEE another user's sockets. The common case for this
# script is precisely that: an earlier `sudo tunnel.sh --console` still running
# in another terminal holds 6443 as root, lsof reports nothing, preflight says
# all clear, and the session then fails to bind with no error of its own. It
# looks like the tunnel simply never came up. Hit for real on 21 Aug 2026.
#
# netstat sees every listener regardless of owner but names no PID, so it is
# the fallback rather than the primary.
port_holder_pid() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1
}
port_is_listening() {
  netstat -an -p tcp 2>/dev/null |
    awk -v port="$1" '$NF == "LISTEN" && $4 ~ ("\\." port "$") { found = 1 } END { exit !found }'
}

idx=0
while [ $idx -lt ${#tunnel_ports[@]} ]; do
  port=${tunnel_ports[$idx]}
  holder=$(port_holder_pid "$port")
  if [ -n "$holder" ]; then
    echo "ERROR: local port $port (${tunnel_labels[$idx]}) is already bound by PID $holder ($(ps -p "$holder" -o comm= 2>/dev/null))." >&2
    echo "A tunnel left running in another terminal is the usual reason." >&2
    exit 1
  elif port_is_listening "$port"; then
    echo "ERROR: local port $port (${tunnel_labels[$idx]}) is already in use by ANOTHER USER's process." >&2
    echo "Almost certainly an earlier 'sudo $(basename "$0")' still running in another terminal." >&2
    echo "Ctrl-C it there, or find it with:" >&2
    echo "  sudo lsof -nP -iTCP:${port} -sTCP:LISTEN" >&2
    exit 1
  fi
  idx=$((idx + 1))
done

# The tunnels bind 127.0.0.1, but the kubeconfig and the browser both use the
# cluster's real names -- so without these entries they are up and unreachable.
# Warned about rather than written: /etc/hosts is the operator's file, not this
# script's.
missing_lines=""
missing_flat=""
for hostlist in "${tunnel_hosts[@]}"; do
  for name in $hostlist; do
    if ! awk -v n="$name" '!/^[[:space:]]*#/ && $1 == "127.0.0.1" {
           for (i = 2; i <= NF; i++) if ($i == n) found = 1
         } END { exit !found }' /etc/hosts; then
      missing_lines="${missing_lines}  ${name}"$'\n'
      missing_flat="${missing_flat}${missing_flat:+ }${name}"
    fi
  done
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
  if [ -z "${AWS_PROFILE:-}" ]; then
    # Almost always the real story when this fires under sudo: the profile is
    # gone, so the CLI used [default] and reported ITS expiry -- which reads as
    # "you are not logged in" when you certainly are.
    echo >&2
    echo "  No AWS_PROFILE is set, so the aws CLI used the [default] profile." >&2
    echo "  If you just logged in and this still fails, that is the cause --" >&2
    echo "  the expired session belongs to a profile you did not mean to use." >&2
    echo "  Name it explicitly instead:" >&2
    echo "    $0 -a ${account_alias}${flags} --profile <aws-profile>" >&2
  else
    echo "  aws sso login --profile ${AWS_PROFILE}" >&2
  fi
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

# ---- the tunnels, each supervised in its own subshell ----

parent_pid=$$
statedir=$(mktemp -d "${TMPDIR:-/tmp}/tunnel.XXXXXX")
child_pids=""

# One tunnel: reconnect through idle timeouts, give up on a real fault.
supervise() {
  local label="$1" port="$2" prefix="$3"
  local session_pid="" stopping=false fast_failures=0
  local started rc ran

  # A subshell resets its inherited traps, so this is the child's own handler
  # rather than the parent's. SIGTERM only: SIGINT is ignored in background
  # children of a non-interactive shell and cannot be trapped there at all,
  # which is why the parent tears children down with TERM instead of relaying
  # a Ctrl-C.
  #
  # It kills the CHILD first. `aws` spawns session-manager-plugin as a
  # subprocess, and the plugin is what actually holds the local port -- killing
  # only the parent orphans it, leaving the port bound after this has exited.
  trap 'stopping=true
        if [ -n "$session_pid" ]; then
          pkill -TERM -P "$session_pid" 2>/dev/null
          kill -TERM "$session_pid" 2>/dev/null
        fi' TERM

  while true; do
    started=$SECONDS
    # Backgrounded and waited on, rather than run in the foreground, because
    # bash defers a trap until the current foreground command finishes -- a
    # SIGTERM would otherwise sit queued behind a session that is not going to
    # end on its own, leaving the port bound. `wait` is interruptible.
    #
    # Output goes through process substitution rather than a pipeline on
    # purpose: in `aws ... | prefixer &`, $! is the PREFIXER, and killing that
    # leaves aws running and holding the port. This way $! is aws itself.
    # awk with fflush() rather than `sed -u`, which is GNU-only -- BSD sed
    # would buffer the output here.
    aws ssm start-session --region "$region" --target "$bastion_id" \
      --document-name AWS-StartPortForwardingSession \
      --parameters "{\"portNumber\":[\"${port}\"],\"localPortNumber\":[\"${port}\"]}" \
      > >(awk -v p="$prefix" '{ print p, $0; fflush() }') 2>&1 &
    session_pid=$!
    wait "$session_pid"
    rc=$?
    wait "$session_pid" 2>/dev/null # reap it if the trap did the killing
    session_pid=""
    ran=$((SECONDS - started))

    [ "$stopping" = "true" ] && return 0

    echo "$prefix [$(date +%H:%M:%S)] session ended after $(fmt_duration "$ran") (exit ${rc}) -- reconnecting"

    # A session that ran for a while and then ended is the documented idle
    # timeout: it exits 0 with nothing on screen, which is the whole reason
    # this loop exists. Reconnect immediately.
    #
    # A session that dies within seconds is a real fault -- expired SSO
    # credentials being the usual one -- and reconnecting just spins. Allow
    # three so a genuine blip still self-heals, then hand the whole run over to
    # the parent: a half-up command is worse than none, and the usual cause
    # breaks every tunnel anyway.
    if [ "$ran" -lt 10 ]; then
      fast_failures=$((fast_failures + 1))
      if [ "$fast_failures" -ge 3 ]; then
        echo "$prefix ${fast_failures} sessions in a row died within seconds (last exit ${rc})." >&2
        echo "$prefix not an idle timeout -- giving up." >&2
        echo "$label" >"$statedir/failed"
        kill -USR1 "$parent_pid" 2>/dev/null
        return 1
      fi
      sleep 5
    else
      fast_failures=0
    fi
  done
}

# shellcheck disable=SC2329  # invoked via the INT/TERM/USR1 traps below
teardown() {
  for cp in $child_pids; do
    kill -TERM "$cp" 2>/dev/null
  done
}

trap teardown INT TERM  # the operator asked to stop
trap teardown USR1      # a tunnel gave up; $statedir/failed names which

echo "bastion ${bastion_id}  SSM Online"
idx=0
while [ $idx -lt ${#tunnel_labels[@]} ]; do
  label=${tunnel_labels[$idx]}
  port=${tunnel_ports[$idx]}
  prefix=$(printf '[%-*s]' "$label_width" "$label")
  echo "$prefix 127.0.0.1:${port} -> bastion:${port}"
  supervise "$label" "$port" "$prefix" &
  child_pids="$child_pids $!"
  idx=$((idx + 1))
done
echo "Ctrl-C to close."

wait
wait 2>/dev/null # children may still be dying when a trap interrupted the first

if [ -f "$statedir/failed" ]; then
  echo >&2
  echo "ERROR: $(cat "$statedir/failed") tunnel failed; all tunnels closed." >&2
  exit 1
fi

echo
echo "tunnels closed."
exit 0
