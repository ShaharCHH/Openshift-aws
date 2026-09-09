#!/usr/bin/env bash
# Manages named per-person cluster logins through the HTPasswd identity
# provider, so kubeadmin's single shared password can be demoted to
# break-glass. See docs/architecture.md ("Cluster login: htpasswd, because
# no identity provider here can hold a credential") for why HTPasswd is the
# only viable IdP here: no cloud-IAM-backed IdP can work under the
# credential wall (CLAUDE.md), and there is no egress path for external
# SSO.
#
# THE CLUSTER SECRET IS THE SOURCE OF TRUTH. The local cache
# (.ignition/<alias>/auth/htpasswd) exists only because bcrypt is one-way --
# it holds no information the secret doesn't. Every mutating mode pulls the
# current htpasswd content from the cluster first, so a stale or missing
# local cache is never a reason to refuse.
#
# NO manifests/auth/*.yaml. OAuth/cluster always already exists (created by
# the CVO, create-only) and spec.identityProviders is
# x-kubernetes-list-type: atomic -- both `oc apply` of a full OAuth object
# and `oc patch --type=merge` replace the ENTIRE provider list with no error
# and no diff. This script never does either; it reads the current list,
# edits the one entry with jq, and always writes the full list back. See
# docs/architecture.md for the verified CRD detail and CLAUDE.md's
# Conventions entry.
#
# `--delete` removes four objects, not one: the htpasswd line, the
# Identity, the User, live oauthaccesstokens/oauthauthorizetokens, and (by
# default) any cluster-admin ClusterRoleBinding naming that user. Removing
# only the htpasswd line leaves existing tokens (up to 24h, verified) and
# console sessions working, and leaves a dangling RBAC binding that would
# silently re-grant cluster-admin if the username is ever reused. See
# docs/architecture.md, "Why each leftover matters".
#
# Targets bash 3.2 (macOS's /usr/bin/env bash) -- no associative arrays, no
# `wait -n`.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  cat >&2 <<'EOF'
usage: manage-cluster-users.sh -a <account-alias> <mode> [options]

Manages named per-person logins through the cluster's HTPasswd identity
provider. The cluster's htpass-secret is the source of truth; the local
cache at .ignition/<alias>/auth/htpasswd is disposable.

Modes (exactly one):
  --list                      who exists, and where: htpasswd, User,
                               Identity, cluster-admin binding. Drift
                               between these shows up here.
  --add <username>            add a new user. Errors if the user already
                               exists in htpasswd -- use --set-password to
                               rotate one on purpose. Bootstraps the secret
                               and the IdP entry if either is absent.
  --set-password <username>   rotate an existing user's password
  --delete <username>         remove from htpasswd AND delete the User,
                               Identity, live tokens, and (unless
                               --keep-rbac) any cluster-admin binding.
                               Also usable as a repair tool: runs the
                               non-htpasswd steps even if the user is
                               already absent from htpasswd.
  --sync                      rewrite the local cache from the cluster;
                               changes nothing in the cluster

Options:
  --admin             also grant cluster-admin (--add / --set-password)
  --password <pw>     use this password instead of generating one
  --password-stdin    read the password from stdin, one line -- nothing in
                       argv or shell history
  --keep-rbac          --delete: leave any cluster-admin binding alone
  --verify             prove `oc login` works via a throwaway kubeconfig
                       (--add / --set-password only)
  --dry-run            print every oc/htpasswd call; change nothing

Every --add / --set-password / --delete rolls all three oauth-openshift
pods (maxSurge:3, maxUnavailable:2) -- logins can briefly fail mid-rollout.
Batch user changes rather than looping this script.
EOF
  exit 1
}

# ---- args ----

account_alias=""
mode=""
username=""
admin=false
password=""
password_stdin=false
keep_rbac=false
verify=false
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --list)
      [ -z "$mode" ] || usage
      mode="list"
      shift
      ;;
    --add)
      [ -z "$mode" ] || usage
      mode="add"
      username="$2"
      shift 2
      ;;
    --set-password)
      [ -z "$mode" ] || usage
      mode="set-password"
      username="$2"
      shift 2
      ;;
    --delete)
      [ -z "$mode" ] || usage
      mode="delete"
      username="$2"
      shift 2
      ;;
    --sync)
      [ -z "$mode" ] || usage
      mode="sync"
      shift
      ;;
    --admin)
      admin=true
      shift
      ;;
    --password)
      password="$2"
      shift 2
      ;;
    --password-stdin)
      password_stdin=true
      shift
      ;;
    --keep-rbac)
      keep_rbac=true
      shift
      ;;
    --verify)
      verify=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    *) usage ;;
  esac
done

[ -n "$account_alias" ] || usage
[ -n "$mode" ] || usage
case "$mode" in
  add | set-password | delete)
    [ -n "$username" ] || usage
    ;;
esac

if [ -n "$password" ] && [ "$password_stdin" = true ]; then
  echo "ERROR: --password and --password-stdin are mutually exclusive." >&2
  exit 1
fi
if [ -n "$password" ] || [ "$password_stdin" = true ]; then
  case "$mode" in
    add | set-password) ;;
    *)
      echo "ERROR: --password/--password-stdin only apply to --add / --set-password." >&2
      exit 1
      ;;
  esac
fi
if [ "$admin" = true ]; then
  case "$mode" in
    add | set-password) ;;
    *)
      echo "ERROR: --admin only applies to --add / --set-password." >&2
      exit 1
      ;;
  esac
fi
if [ "$keep_rbac" = true ] && [ "$mode" != "delete" ]; then
  echo "ERROR: --keep-rbac only applies to --delete." >&2
  exit 1
fi
if [ "$verify" = true ]; then
  case "$mode" in
    add | set-password) ;;
    *)
      echo "ERROR: --verify only applies to --add / --set-password." >&2
      exit 1
      ;;
  esac
fi

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || {
  echo "ERROR: $tfvars not found." >&2
  exit 1
}

cluster_name=$(read_tfvar cluster_name "$tfvars")
base_domain=$(read_tfvar base_domain "$tfvars")
if [ -z "$cluster_name" ] || [ -z "$base_domain" ]; then
  echo "ERROR: cluster_name / base_domain must both be set in $tfvars" >&2
  exit 1
fi

command -v oc >/dev/null 2>&1 || {
  echo "ERROR: oc not found on PATH." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq not found on PATH." >&2
  exit 1
}
command -v htpasswd >/dev/null 2>&1 || {
  echo "ERROR: htpasswd not found on PATH (Apache httpd tools)." >&2
  exit 1
}

KC="$repo_root/.ignition/${account_alias}/auth/kubeconfig"
[ -f "$KC" ] || {
  echo "ERROR: $KC not found -- run scripts/ignition/generate-ignition.sh first." >&2
  exit 1
}
HT_DIR="$repo_root/.ignition/${account_alias}/auth"
HT="$HT_DIR/htpasswd"
IDP="htpasswd"
SECRET="htpass-secret"
api_url="https://api.${cluster_name}.${base_domain}:6443"

run_oc() {
  oc --kubeconfig="$KC" "$@"
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/manage-cluster-users.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

echo "account: ${account_alias}   cluster: ${cluster_name}.${base_domain}   mode: --${mode}"

# ---- pull current htpasswd content from the cluster (source of truth) ----
#
# base64 -d, not -D: matches trust-cluster-ca.sh's convention (portable
# between macOS's BSD base64 and GNU coreutils).
pull_cluster_htpasswd() {
  local b64
  b64=$(run_oc -n openshift-config get secret "$SECRET" \
    -o jsonpath='{.data.htpasswd}' 2>/dev/null || true)
  if [ -z "$b64" ]; then
    : >"$tmp_dir/htpasswd"
    return 0
  fi
  echo "$b64" | base64 -d >"$tmp_dir/htpasswd"
}

pull_cluster_htpasswd

if [ -f "$HT" ] && ! diff -q "$HT" "$tmp_dir/htpasswd" >/dev/null 2>&1; then
  local_only=$(awk -F: 'NR==FNR{c[$1]=1;next} !($1 in c)' "$tmp_dir/htpasswd" "$HT" 2>/dev/null || true)
  if [ -n "$local_only" ]; then
    echo "WARNING: local cache $HT differs from the cluster secret." >&2
    echo "  Usernames only in the local cache (stale, proceeding from the cluster copy):" >&2
    echo "$local_only" | awk -F: '{print "    " $1}' >&2
  else
    echo "WARNING: local cache $HT differs from the cluster secret (proceeding from the cluster copy)." >&2
  fi
fi

# ---- helpers ----

# Prints "user:hash" on stdout. -n prints to stdout instead of editing a
# file (sidesteps -c's truncate-on-create hazard); -i reads the password
# from stdin so it never appears in argv/ps; -C 10 because the default
# cost is 5 ($2y$05$, verified too cheap for a shared cluster).
hash_password() {
  local user="$1" pw="$2"
  printf '%s\n' "$pw" | htpasswd -niB -C 10 "$user"
}

generate_password() {
  openssl rand -base64 24 | tr -d '=+/' | cut -c1-20
}

# Splices $1 out of the working htpasswd file (if present) and appends
# $2 (a "user:hash" line) if given. awk, never grep -v: grep -v exits 1
# when it filters out every line, which under set -e kills the script the
# moment you delete the last user.
splice_htpasswd() {
  local user="$1" newline="${2:-}"
  awk -F: -v u="$user" '$1 != u' "$tmp_dir/htpasswd" >"$tmp_dir/htpasswd.next"
  if [ -n "$newline" ]; then
    printf '%s\n' "$newline" >>"$tmp_dir/htpasswd.next"
  fi
  mv "$tmp_dir/htpasswd.next" "$tmp_dir/htpasswd"
}

user_in_htpasswd() {
  awk -F: -v u="$1" '$1 == u {found=1} END{exit !found}' "$tmp_dir/htpasswd" 2>/dev/null
}

# Writes $tmp_dir/htpasswd to the cluster secret and ensures the OAuth CR's
# identityProviders list has an entry named $IDP pointing at it -- an
# in-place edit of one entry, never a full-list replace (see header).
push_secret_and_idp() {
  if [ "$dry_run" = true ]; then
    echo "[dry-run] would push $SECRET (openshift-config) from $tmp_dir/htpasswd:"
    awk -F: '{print "  " $1}' "$tmp_dir/htpasswd"
  else
    run_oc -n openshift-config create secret generic "$SECRET" \
      --from-file=htpasswd="$tmp_dir/htpasswd" --dry-run=client -o yaml |
      run_oc apply -f -
    echo "pushed $SECRET"
  fi

  local current desired
  current=$(run_oc get oauth cluster -o jsonpath='{.spec.identityProviders}' 2>/dev/null || true)
  [ -n "$current" ] || current='[]'
  desired=$(jq -c --arg n "$IDP" --arg s "$SECRET" '
    def entry: { name: $n, mappingMethod: "claim", type: "HTPasswd",
                 htpasswd: { fileData: { name: $s } } };
    if any(.[]; .name == $n) then map(if .name == $n then entry else . end)
                             else . + [entry] end' <<<"$current")

  # Equality guard: a no-op patch still bumps resourceVersion and rolls all
  # three oauth-openshift pods.
  if [ "$(jq -S -c . <<<"$current")" = "$(jq -S -c . <<<"$desired")" ]; then
    echo "identityProviders already up to date -- no patch needed."
    return 0
  fi
  if [ "$dry_run" = true ]; then
    echo "[dry-run] would patch oauth/cluster identityProviders to:"
    jq . <<<"$desired"
    return 0
  fi
  run_oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":${desired}}}"
  echo "patched oauth/cluster identityProviders"
}

sync_local_cache() {
  mkdir -p "$HT_DIR"
  ( umask 077; cp "$tmp_dir/htpasswd" "$HT" )
  chmod 0600 "$HT"
  echo "synced local cache: $HT"
}

wait_for_authentication() {
  echo "NOTE: network and storage cluster operators are permanently Progressing=True" \
    "on this cluster (see docs/runbook.md, Known-inert) -- do not wait on them." >&2

  # co/authentication's own conditions are NOT enough on their own: verified
  # live that it reports Available=True/Progressing=False/Degraded=False
  # while the oauth-openshift Deployment is still mid-rollout (old pods
  # Terminating, new ones Pending) -- a login attempt in that window can
  # still 401 against a pod that hasn't picked up the new secret yet. Wait
  # for the Deployment rollout first, then confirm the ClusterOperator.
  #
  # One rollout is not always enough, either: also verified live that the
  # authentication operator can react to the secret change with a short lag
  # and kick off a SECOND, corrective rollout just after the first one
  # converges (`oc rollout status` reported success for a rollout started
  # from a stale rvs-hash, then a fresh rollout carrying the real content
  # began ~15s later). So keep re-checking the Deployment's generation after
  # each successful rollout until it stops changing.
  echo "waiting for the oauth-openshift rollout (maxSurge:3, maxUnavailable:2 -- expect ~60-90s, sometimes twice)..."
  local prev_gen="" cur_gen rollout_count=0
  while [ "$rollout_count" -lt 5 ]; do
    if ! run_oc -n openshift-authentication rollout status deploy/oauth-openshift --timeout=300s; then
      echo "WARNING: oauth-openshift rollout did not complete within 5 minutes -- check by hand:" >&2
      echo "  oc --kubeconfig=$KC -n openshift-authentication get pods" >&2
      return 1
    fi
    rollout_count=$((rollout_count + 1))
    cur_gen=$(run_oc -n openshift-authentication get deploy oauth-openshift -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
    if [ "$cur_gen" = "$prev_gen" ]; then
      break
    fi
    prev_gen="$cur_gen"
    sleep 15
  done

  echo "waiting for co/authentication to settle..."
  local i=0
  while [ "$i" -lt 60 ]; do
    local avail progressing degraded
    avail=$(run_oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
    progressing=$(run_oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)
    degraded=$(run_oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)
    if [ "$avail" = "True" ] && [ "$progressing" = "False" ] && [ "$degraded" = "False" ]; then
      echo "co/authentication: Available=True Progressing=False Degraded=False"
      return 0
    fi
    sleep 5
    i=$((i + 1))
  done
  echo "WARNING: co/authentication did not settle within 5 minutes -- check by hand:" >&2
  echo "  oc --kubeconfig=$KC get co authentication" >&2
  return 1
}

do_verify() {
  local user="$1" pw="$2" tmpkc who
  tmpkc="$tmp_dir/verify-kubeconfig"
  echo "verifying: oc login as $user"
  if ! oc login "$api_url" -u "$user" -p "$pw" --kubeconfig="$tmpkc" >/dev/null 2>"$tmp_dir/login.err"; then
    echo "ERROR: oc login as $user failed:" >&2
    sed 's/^/  /' "$tmp_dir/login.err" >&2
    return 1
  fi
  who=$(oc --kubeconfig="$tmpkc" whoami 2>/dev/null || true)
  if [ "$who" != "$user" ]; then
    echo "ERROR: logged in but 'oc whoami' returned '$who', expected '$user'." >&2
    return 1
  fi
  echo "verified: oc whoami -> $user"
}

# ---- modes ----

mode_list() {
  echo
  echo "-- htpasswd (secret: openshift-config/$SECRET) --"
  if [ -s "$tmp_dir/htpasswd" ]; then
    awk -F: '{print "  " $1}' "$tmp_dir/htpasswd"
  else
    echo "  (secret absent or empty)"
  fi

  echo
  echo "-- Identity objects (${IDP}:<username>) --"
  run_oc get identity -o jsonpath="{range .items[?(@.providerName==\"${IDP}\")]}{.providerUserName}{\"\n\"}{end}" 2>/dev/null |
    sed 's/^/  /' || true

  echo
  echo "-- User objects with an htpasswd identity --"
  run_oc get identity -o jsonpath="{range .items[?(@.providerName==\"${IDP}\")]}{.user.name}{\"\n\"}{end}" 2>/dev/null |
    sed 's/^/  /' || true

  echo
  echo "-- cluster-admin ClusterRoleBindings (scanned by roleRef, not by name) --"
  run_oc get clusterrolebindings \
    -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{.metadata.name}{": "}{range .subjects[*]}{.kind}{"/"}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null |
    sed 's/^/  /' || true
  echo
}

mode_add() {
  if user_in_htpasswd "$username"; then
    echo "ERROR: '$username' already exists in htpasswd -- use --set-password to rotate it." >&2
    exit 1
  fi
  local pw
  if [ -n "$password" ]; then
    pw="$password"
  elif [ "$password_stdin" = true ]; then
    IFS= read -r pw
  else
    pw=$(generate_password)
    echo "generated password for $username: $pw"
  fi
  local line
  line=$(hash_password "$username" "$pw")
  splice_htpasswd "$username" "$line"
  push_secret_and_idp
  if [ "$dry_run" = true ]; then
    echo "[dry-run] would grant cluster-admin to $username" && [ "$admin" = true ]
    return 0
  fi
  sync_local_cache
  if [ "$admin" = true ]; then
    # `oc adm policy add-cluster-role-to-user` prints "Warning: User 'x' not
    # found" -- expected and harmless. RBAC subjects are plain strings and
    # the User object is created on first login by claim mapping. This
    # creates a fresh ClusterRoleBinding/cluster-admin-N, not an edit of the
    # bootstrap cluster-admin CRB -- hence --list scans by roleRef.
    run_oc adm policy add-cluster-role-to-user cluster-admin "$username" || true
    echo "granted cluster-admin to $username"
  fi
  wait_for_authentication || true
  if [ "$verify" = true ]; then
    do_verify "$username" "$pw"
  fi
}

mode_set_password() {
  if ! user_in_htpasswd "$username"; then
    echo "ERROR: '$username' does not exist in htpasswd -- use --add." >&2
    exit 1
  fi
  local pw
  if [ -n "$password" ]; then
    pw="$password"
  elif [ "$password_stdin" = true ]; then
    IFS= read -r pw
  else
    pw=$(generate_password)
    echo "generated password for $username: $pw"
  fi
  local line
  line=$(hash_password "$username" "$pw")
  splice_htpasswd "$username" "$line"
  push_secret_and_idp
  if [ "$dry_run" = true ]; then
    return 0
  fi
  sync_local_cache
  if [ "$admin" = true ]; then
    run_oc adm policy add-cluster-role-to-user cluster-admin "$username" || true
    echo "granted cluster-admin to $username"
  fi
  wait_for_authentication || true
  if [ "$verify" = true ]; then
    do_verify "$username" "$pw"
  fi
}

mode_delete() {
  # Step 1: htpasswd first, so no new login can start with the old
  # password while the rest of this runs.
  if user_in_htpasswd "$username"; then
    splice_htpasswd "$username"
    push_secret_and_idp
    sync_local_cache
  else
    echo "NOTE: '$username' not present in htpasswd -- continuing to clean up" \
      "Identity/User/tokens/RBAC in case this is a repair run." >&2
  fi

  # Step 2: Identity and User. Deleting the User is the actual revocation --
  # the token authenticator resolves userName -> User and compares UIDs, so
  # this is what stops her existing 24h tokens and open console tab, not
  # step 1. Not instantaneous -- there's a short positive-auth cache in
  # front of that check -- but fast: measured live, a token still worked
  # 10s after this delete step completed and was rejected by 25s. Nowhere
  # near the up-to-24h exposure of stopping at step 1 alone.
  if [ "$dry_run" = true ]; then
    echo "[dry-run] would delete identity ${IDP}:${username}"
    echo "[dry-run] would delete user ${username}"
  else
    run_oc delete identity "${IDP}:${username}" --ignore-not-found
    run_oc delete user "$username" --ignore-not-found
  fi

  # Step 3: sweep live tokens naming this user. Belt-and-suspenders with
  # step 2 -- `oc delete user` does not itself delete tokens.
  local tok
  for tok in $(run_oc get oauthaccesstokens -o jsonpath="{range .items[?(@.userName==\"${username}\")]}{.metadata.name}{\" \"}{end}" 2>/dev/null || true); do
    [ -n "$tok" ] || continue
    if [ "$dry_run" = true ]; then
      echo "[dry-run] would delete oauthaccesstoken $tok"
    else
      run_oc delete oauthaccesstoken "$tok" --ignore-not-found
    fi
  done
  for tok in $(run_oc get oauthauthorizetokens -o jsonpath="{range .items[?(@.userName==\"${username}\")]}{.metadata.name}{\" \"}{end}" 2>/dev/null || true); do
    [ -n "$tok" ] || continue
    if [ "$dry_run" = true ]; then
      echo "[dry-run] would delete oauthauthorizetoken $tok"
    else
      run_oc delete oauthauthorizetoken "$tok" --ignore-not-found
    fi
  done

  # Step 4: dangling RBAC is the worst leftover -- the binding names the
  # plain string $username, and re-adding that username later would
  # silently restore cluster-admin. Removed by default; --keep-rbac opts
  # out.
  if [ "$keep_rbac" = true ]; then
    echo "NOTE: --keep-rbac set -- leaving any cluster-admin binding for '$username' in place." >&2
  else
    if [ "$dry_run" = true ]; then
      echo "[dry-run] would remove cluster-admin from $username (if bound)"
    else
      run_oc adm policy remove-cluster-role-from-user cluster-admin "$username" 2>/dev/null || true
    fi
  fi

  [ "$dry_run" = true ] || wait_for_authentication || true
}

mode_sync() {
  sync_local_cache
}

case "$mode" in
  list) mode_list ;;
  add) mode_add ;;
  set-password) mode_set_password ;;
  delete) mode_delete ;;
  sync) mode_sync ;;
esac
