#!/usr/bin/env bash
# Installs the cluster's own API and ingress CAs into this machine's trust
# store, so oc/curl/the browser stop rejecting TLS served through the
# tunnel (scripts/tunnel.sh).
#
# WHY THIS EXISTS: there is no public CA anywhere in this design and there
# cannot be one -- no Route 53, no ELB, no public endpoint (docs/scp-blockers.md
# rows 1, 3, 4). The cluster is its own CA. `oc` is already unaffected --
# openshift-install's admin kubeconfig embeds the API CA inline -- but a
# browser hitting the console, or curl, consults the OS trust store instead
# and has never heard of either root. See docs/architecture.md for the two
# CAs this installs and why only one cert from each bundle is the right one
# (each bundle has 2-3 self-signed roots; only ONE of them signs anything
# this machine ever talks to -- trusting the others machine-wide buys
# nothing and widens the blast radius for no reason).
#
# Two sources per CA, tried in order:
#   API CA:     .ignition/<alias>/auth/kubeconfig (offline, no cluster
#               contact) -> TLS chain scraped off 127.0.0.1:6443 (TOFU)
#   ingress CA: cm/default-ingress-cert (needs the cluster reachable through
#               the tunnel) -> TLS chain scraped off 127.0.0.1:443 (TOFU)
# A scraped root is trusted only after three checks: it is self-signed, the
# leaf on the wire verifies against it, and the leaf's SAN covers the name
# we asked for. Any of those failing is a hard error, not a warning -- this
# is the one place in the script that would otherwise trust whatever
# answered a socket.
#
# Reads everything from accounts/<alias>.tfvars, so like tunnel.sh and
# update-kubeconfig.sh this needs no terraform state and no particular
# working directory.
#
# Targets bash 3.2 (macOS's /usr/bin/env bash) -- no associative arrays, no
# `wait -n`. Runs on Linux too (update-ca-trust / update-ca-certificates).
set -uo pipefail # NOT -e: a failed cluster contact is normal input to the
                 # fallback path here, not a reason to abort.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  cat >&2 <<'EOF'
usage: trust-cluster-ca.sh -a <account-alias> [options]

Installs the cluster's own API and ingress CAs (both self-signed -- there is
no public CA to get instead, see docs/architecture.md) into this machine's
trust store.

  --user           login keychain instead of the system keychain (macOS
                    only, no sudo needed). Linux has no per-user equivalent
                    of the trust stores this touches, so this errors there.
  --api-only       only the API CA (api.<cluster>.<domain>:6443)
  --ingress-only   only the ingress CA (*.apps.<cluster>.<domain>)
  --uninstall      remove, instead of install
  --dry-run        show what would happen; touches no trust store and
                    never needs root

The API CA is read from .ignition/<alias>/auth/kubeconfig -- offline, no
cluster contact. The ingress CA is read from the cluster itself
(cm/default-ingress-cert), which needs
  scripts/tunnel.sh -a <alias> --all
running. Either falls back to scraping the TLS chain off the tunnel's local
port if its normal source is unavailable.

Installing into the system trust store needs root:
  sudo ./scripts/trust-cluster-ca.sh -a <alias>
EOF
  exit 1
}

# ---- args ----

account_alias=""
keychain_scope="system"
want_api=true
want_ingress=true
saw_api_only=false
saw_ingress_only=false
mode="install"
dry_run=false
cli_flags="" # echoed back in the sudo hint, so it reproduces the full request

while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
      ;;
    --user)
      keychain_scope="user"
      cli_flags="$cli_flags --user"
      shift
      ;;
    --api-only)
      saw_api_only=true
      cli_flags="$cli_flags --api-only"
      shift
      ;;
    --ingress-only)
      saw_ingress_only=true
      cli_flags="$cli_flags --ingress-only"
      shift
      ;;
    --uninstall)
      mode="uninstall"
      cli_flags="$cli_flags --uninstall"
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

if [ "$saw_api_only" = true ] && [ "$saw_ingress_only" = true ]; then
  echo "ERROR: --api-only and --ingress-only are mutually exclusive." >&2
  exit 1
elif [ "$saw_api_only" = true ]; then
  want_ingress=false
elif [ "$saw_ingress_only" = true ]; then
  want_api=false
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

command -v openssl >/dev/null 2>&1 || {
  echo "ERROR: openssl not found on PATH." >&2
  exit 1
}
command -v oc >/dev/null 2>&1 || {
  echo "ERROR: oc not found on PATH." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq not found on PATH." >&2
  exit 1
}

# ---- platform ----

detect_platform() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    *)
      if [ -d /etc/pki/ca-trust/source/anchors ]; then
        echo rhel
      elif [ -d /usr/local/share/ca-certificates ]; then
        echo debian
      else
        echo unsupported
      fi
      ;;
  esac
}
platform=$(detect_platform)

if [ "$keychain_scope" = "user" ] && [ "$platform" != "macos" ]; then
  echo "ERROR: --user is macOS-only (a per-user trust store keyed to \$HOME/Library/Keychains/login.keychain-db)." >&2
  echo "Linux's trust store here has no per-user equivalent -- omit --user." >&2
  exit 1
fi

# System-store installs need root; --dry-run touches nothing and never does.
# Caught here rather than left to fail on the write, same as tunnel.sh's
# port-1024 check.
needs_root=false
case "$platform" in
  macos) [ "$keychain_scope" = "system" ] && needs_root=true ;;
  rhel | debian) needs_root=true ;;
esac
if [ "$dry_run" = false ] && [ "$needs_root" = true ] && [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: the system trust store needs root for this." >&2
  echo "Re-run as:" >&2
  echo "  sudo $0 -a ${account_alias}${cli_flags}" >&2
  exit 1
fi

# ---- names this cluster's certs should cover ----

api_name="api.${cluster_name}.${base_domain}"
# The wildcard cert's own CN can't be used as an SNI/SAN target literally
# ("*.apps...") -- console-openshift-console is the same concrete hostname
# tunnel.sh already uses for the same reason (see its --console block).
console_name="console-openshift-console.apps.${cluster_name}.${base_domain}"
kubeconfig_path="$repo_root/.ignition/${account_alias}/auth/kubeconfig"

echo "account: ${account_alias}   cluster: ${cluster_name}.${base_domain}   platform: ${platform}"

# ---- run oc as the invoking user, not root ----
#
# The other half of tunnel.sh's restore_aws_ownership story (tunnel.sh:172-188):
# oc caches under ~/.kube/cache and ~/.kube/http-cache, and a sudo run that
# writes there as root breaks the NEXT ordinary, non-sudo `oc` call with a
# permission error days later, from a cause that looks nothing like this
# script. Run oc as $SUDO_USER when there is one; sudo -u sets that user's
# real HOME on its own, so this needs no -E gymnastics.
run_oc() {
  if [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" oc "$@"
  else
    oc "$@"
  fi
}

# Safety net for the above, modelled on tunnel.sh's restore_aws_ownership --
# catches anything that slips past run_oc rather than leaving root-owned
# files for the operator to puzzle over later.
# shellcheck disable=SC2329  # invoked via the EXIT trap, through cleanup
restore_kube_ownership() {
  [ -n "${SUDO_USER:-}" ] || return 0
  local user_home
  user_home=$(eval echo "~${SUDO_USER}" 2>/dev/null)
  [ -n "$user_home" ] && [ -d "$user_home/.kube" ] || return 0
  find "$user_home/.kube" -user 0 -exec chown "$SUDO_USER" {} + 2>/dev/null || true
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/trust-cluster-ca.XXXXXX")
had_error=false

# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() {
  restore_kube_ownership
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

# ---- small helpers ----

# No `nc`/`netstat` flag assumed portable between macOS and Linux here --
# bash's own /dev/tcp works the same on both.
port_is_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Splits a multi-cert PEM bundle into cert-1.pem, cert-2.pem, ... in $2.
# `openssl x509` on its own only ever reads the FIRST cert in a bundle and
# says nothing about the rest -- this is what stands between "read a bundle"
# and "silently pick the wrong cert out of it".
split_pem_bundle() {
  local bundle="$1" outdir="$2"
  mkdir -p "$outdir"
  awk -v dir="$outdir" '
    /-----BEGIN CERTIFICATE-----/ { n++; capturing=1 }
    capturing { print > (dir "/cert-" n ".pem") }
    /-----END CERTIFICATE-----/ { capturing=0 }
    END { print n > (dir "/.count") }
  ' "$bundle"
}

# Prints the one cert in a bundle whose subject matches $2, if any.
extract_cert_matching() {
  local bundle="$1" pattern="$2" tmp f found=""
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ca-split.XXXXXX")
  split_pem_bundle "$bundle" "$tmp"
  for f in "$tmp"/cert-*.pem; do
    [ -e "$f" ] || continue
    if openssl x509 -noout -subject -in "$f" 2>/dev/null | grep -q "$pattern"; then
      found="$f"
      break
    fi
  done
  [ -n "$found" ] && cat "$found"
  rm -rf "$tmp"
  [ -n "$found" ]
}

# Prints the one cert in a bundle that is self-signed (subject == issuer).
extract_self_signed() {
  local bundle="$1" tmp f subj issr found=""
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ca-split.XXXXXX")
  split_pem_bundle "$bundle" "$tmp"
  for f in "$tmp"/cert-*.pem; do
    [ -e "$f" ] || continue
    subj=$(openssl x509 -noout -subject -in "$f" 2>/dev/null | sed 's/^subject=//')
    issr=$(openssl x509 -noout -issuer -in "$f" 2>/dev/null | sed 's/^issuer=//')
    if [ -n "$subj" ] && [ "$subj" = "$issr" ]; then
      found="$f"
      break
    fi
  done
  [ -n "$found" ] && cat "$found"
  rm -rf "$tmp"
  [ -n "$found" ]
}

# Fetches the TLS chain served on 127.0.0.1:$1 for SNI $2, leaf first, into
# $3/leaf.pem and $3/root.pem (last cert sent). `-text`, not the newer `-ext`
# flag, for SAN parsing below -- `-ext` isn't in every openssl/LibreSSL build
# this might run against, `-text` always has been.
fetch_chain_via_scrape() {
  local port="$1" sni="$2" outdir="$3" count
  mkdir -p "$outdir"
  # </dev/null so s_client doesn't sit waiting for input that never comes.
  openssl s_client -connect "127.0.0.1:${port}" -servername "$sni" -showcerts \
    </dev/null >"$outdir/raw.txt" 2>/dev/null
  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "$outdir/raw.txt" >"$outdir/chain.pem"
  [ -s "$outdir/chain.pem" ] || return 1
  split_pem_bundle "$outdir/chain.pem" "$outdir"
  count=$(cat "$outdir/.count" 2>/dev/null || echo 0)
  [ "$count" -ge 1 ] 2>/dev/null || return 1
  cp "$outdir/cert-1.pem" "$outdir/leaf.pem"
  cp "$outdir/cert-${count}.pem" "$outdir/root.pem"
}

scrape_leaf_sans() {
  openssl x509 -noout -text -in "$1" 2>/dev/null |
    awk '/X509v3 Subject Alternative Name/{ getline; print }' |
    tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p'
}

# $1 expected hostname, $2 leaf cert. Exact match, or wildcard ("*.<suffix>"
# covers any single-label name ending in ".<suffix>").
name_matches_san() {
  local expected="$1" leaf="$2" san suffix
  while IFS= read -r san; do
    [ -n "$san" ] || continue
    if [ "$san" = "$expected" ]; then
      return 0
    fi
    case "$san" in
      [*].*)
        suffix="${san#\*.}"
        case "$expected" in
          *".${suffix}") return 0 ;;
        esac
        ;;
    esac
  done <<EOF
$(scrape_leaf_sans "$leaf")
EOF
  return 1
}

# Refuses to trust a scraped root unless it is self-signed, the leaf served
# alongside it actually chains to it, and the leaf covers the name we asked
# for. This is the one place a wrong answer on a socket could otherwise
# become a trusted CA.
verify_scraped_root() {
  local leaf="$1" root="$2" expected="$3" port="$4" subj issr
  subj=$(openssl x509 -noout -subject -in "$root" 2>/dev/null | sed 's/^subject=//')
  issr=$(openssl x509 -noout -issuer -in "$root" 2>/dev/null | sed 's/^issuer=//')
  if [ -z "$subj" ] || [ "$subj" != "$issr" ]; then
    echo "ERROR: the root scraped from 127.0.0.1:${port} ('${subj}') is not self-signed -- refusing to trust it." >&2
    return 1
  fi
  if ! openssl verify -CAfile "$root" "$leaf" >/dev/null 2>&1; then
    echo "ERROR: the leaf served on 127.0.0.1:${port} does not chain to the root sent alongside it -- refusing to trust it." >&2
    return 1
  fi
  if ! name_matches_san "$expected" "$leaf"; then
    echo "ERROR: the leaf served on 127.0.0.1:${port} does not cover ${expected} -- refusing to trust the scraped root." >&2
    echo "  Either the wrong thing answered on that port, or cluster_name/base_domain in $tfvars are stale." >&2
    return 1
  fi
}

fingerprint_of() {
  openssl x509 -noout -fingerprint -sha1 -in "$1" 2>/dev/null | sed 's/^.*=//; s/://g'
}
cn_of() {
  openssl x509 -noout -subject -in "$1" 2>/dev/null |
    sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p'
}

# Keeps a copy of every CA this run resolves under .ignition/ -- gitignored
# already, same as the rest of that directory (CLAUDE.md) -- so it survives
# $tmp_dir being removed on exit and there's something to point at if the
# platform branch below can't act on it automatically.
persist_ca() {
  local which="$1" src="$2" dir="$repo_root/.ignition/${account_alias}/certs"
  mkdir -p "$dir"
  cp "$src" "$dir/${which}-ca.pem"
  echo "$dir/${which}-ca.pem"
}

# ---- acquire: API CA ----

acquire_api_ca() {
  api_ca_file=""
  api_ca_source=""

  if [ -f "$kubeconfig_path" ]; then
    local ca_b64
    ca_b64=$(run_oc config view --kubeconfig="$kubeconfig_path" --raw -o json 2>/dev/null |
      jq -r '.clusters[0].cluster."certificate-authority-data" // empty')
    if [ -n "$ca_b64" ]; then
      echo "$ca_b64" | base64 -d >"$tmp_dir/api-bundle.pem" 2>/dev/null
      if extract_cert_matching "$tmp_dir/api-bundle.pem" "kube-apiserver-lb-signer" >"$tmp_dir/api-ca.pem"; then
        api_ca_file="$tmp_dir/api-ca.pem"
        api_ca_source="$kubeconfig_path (offline)"
        return 0
      fi
    fi
    echo "WARNING: $kubeconfig_path did not yield a kube-apiserver-lb-signer cert -- falling back to the TLS endpoint." >&2
  else
    echo "WARNING: $kubeconfig_path not found -- falling back to the TLS endpoint." >&2
  fi

  if ! port_is_open 6443; then
    echo "ERROR: no API CA available -- $kubeconfig_path is missing and 127.0.0.1:6443 isn't listening." >&2
    echo "Run scripts/tunnel.sh -a ${account_alias} --api first, or regenerate ignition to produce the kubeconfig." >&2
    return 1
  fi

  local dir="$tmp_dir/api-scrape"
  if ! fetch_chain_via_scrape 6443 "$api_name" "$dir"; then
    echo "ERROR: could not fetch a TLS chain from 127.0.0.1:6443." >&2
    return 1
  fi
  verify_scraped_root "$dir/leaf.pem" "$dir/root.pem" "$api_name" 6443 || return 1
  echo "NOTE: API CA is trust-on-first-use from the TLS chain on 127.0.0.1:6443 (kubeconfig unavailable)." >&2
  api_ca_file="$dir/root.pem"
  api_ca_source="TLS endpoint scrape, 127.0.0.1:6443 (TOFU)"
}

# ---- acquire: ingress CA ----

acquire_ingress_ca() {
  ingress_ca_file=""
  ingress_ca_source=""

  if [ -f "$kubeconfig_path" ]; then
    local bundle
    bundle=$(run_oc --kubeconfig="$kubeconfig_path" --request-timeout=15s \
      get cm default-ingress-cert -n openshift-config-managed \
      -o jsonpath='{.data.ca-bundle\.crt}' 2>"$tmp_dir/oc-ingress.err")
    if [ -n "$bundle" ]; then
      printf '%s' "$bundle" >"$tmp_dir/ingress-bundle.pem"
      if extract_self_signed "$tmp_dir/ingress-bundle.pem" >"$tmp_dir/ingress-ca.pem"; then
        ingress_ca_file="$tmp_dir/ingress-ca.pem"
        ingress_ca_source="cm/default-ingress-cert (cluster)"
        return 0
      fi
      echo "WARNING: default-ingress-cert did not contain a self-signed root -- falling back to the TLS endpoint." >&2
    else
      echo "WARNING: could not read cm/default-ingress-cert from the cluster -- falling back to the TLS endpoint." >&2
      [ -s "$tmp_dir/oc-ingress.err" ] && sed 's/^/  /' "$tmp_dir/oc-ingress.err" >&2
    fi
  else
    echo "WARNING: $kubeconfig_path not found -- falling back to the TLS endpoint." >&2
  fi

  if ! port_is_open 443; then
    echo "ERROR: no ingress CA available -- the cluster wasn't reachable and 127.0.0.1:443 isn't listening." >&2
    echo "Run:  sudo ./scripts/tunnel.sh -a ${account_alias} --console --profile <aws-profile>" >&2
    echo "(or --all to get both tunnels from one terminal)" >&2
    return 1
  fi

  local dir="$tmp_dir/ingress-scrape"
  if ! fetch_chain_via_scrape 443 "$console_name" "$dir"; then
    echo "ERROR: could not fetch a TLS chain from 127.0.0.1:443." >&2
    return 1
  fi
  verify_scraped_root "$dir/leaf.pem" "$dir/root.pem" "$console_name" 443 || return 1
  echo "NOTE: ingress CA is trust-on-first-use from the TLS chain on 127.0.0.1:443 (cluster unreachable)." >&2
  ingress_ca_file="$dir/root.pem"
  ingress_ca_source="TLS endpoint scrape, 127.0.0.1:443 (TOFU)"
}

# ---- apply: macOS ----

macos_keychain_path() {
  if [ "$keychain_scope" = "user" ]; then
    echo "$HOME/Library/Keychains/login.keychain-db"
  else
    echo "/Library/Keychains/System.keychain"
  fi
}
macos_cert_present() {
  security find-certificate -a -Z "$1" 2>/dev/null | grep -qi "SHA-1 hash: $2"
}

apply_macos() {
  local which="$1" cert_file="$2" source_desc="$3" keychain fp cn stale
  keychain=$(macos_keychain_path)
  fp=$(fingerprint_of "$cert_file")
  cn=$(cn_of "$cert_file")

  if [ "$mode" = "uninstall" ]; then
    if ! macos_cert_present "$keychain" "$fp"; then
      echo "${which}: not present in $keychain -- nothing to remove."
      return 0
    fi
    if [ "$dry_run" = true ]; then
      echo "[dry-run] ${which}: would remove $cn ($fp) from $keychain"
      return 0
    fi
    security delete-certificate -Z "$fp" -t "$keychain"
    echo "${which}: removed $cn ($fp) from $keychain"
    return 0
  fi

  if macos_cert_present "$keychain" "$fp"; then
    echo "${which}: already trusted -- $cn ($fp) in $keychain [source: $source_desc]"
    return 0
  fi

  # Best-effort: flag same-CN entries under a DIFFERENT fingerprint, most
  # likely a stale root from an earlier cluster build. `create manifests`
  # mints a fresh CA every rebuild (CLAUDE.md) and the CN itself is a
  # constant across every cluster this repo builds, so a stale entry can't
  # be matched back to an alias automatically -- surfaced, not auto-removed.
  stale=$(security find-certificate -a -c "$cn" -Z "$keychain" 2>/dev/null |
    awk -v fp="$fp" '/SHA-1 hash:/ { if ($NF != fp) print $NF }')
  if [ -n "$stale" ]; then
    echo "NOTE: $keychain already trusts other '$cn' certs (likely an earlier cluster build):" >&2
    while IFS= read -r h; do
      [ -n "$h" ] && echo "  security delete-certificate -Z $h -t \"$keychain\"" >&2
    done <<EOF
$stale
EOF
  fi

  if [ "$dry_run" = true ]; then
    echo "[dry-run] ${which}: would add $cn ($fp) to $keychain [source: $source_desc]"
    return 0
  fi
  if [ "$keychain_scope" = "system" ]; then
    security add-trusted-cert -d -r trustRoot -k "$keychain" "$cert_file"
  else
    security add-trusted-cert -r trustRoot -k "$keychain" "$cert_file"
  fi
  echo "${which}: trusted $cn ($fp) in $keychain [source: $source_desc]"
}

# ---- apply: Linux ----

linux_dest_path() {
  case "$platform" in
    rhel) echo "/etc/pki/ca-trust/source/anchors/openshift-${account_alias}-${1}-ca.crt" ;;
    debian) echo "/usr/local/share/ca-certificates/openshift-${account_alias}-${1}-ca.crt" ;;
  esac
}
linux_refresh() {
  case "$platform" in
    rhel) update-ca-trust extract ;;
    debian) update-ca-certificates >/dev/null ;;
  esac
}

apply_linux() {
  local which="$1" cert_file="$2" source_desc="$3" dest fp cn
  dest=$(linux_dest_path "$which")
  fp=$(fingerprint_of "$cert_file")
  cn=$(cn_of "$cert_file")

  if [ "$mode" = "uninstall" ]; then
    if [ ! -f "$dest" ]; then
      echo "${which}: not present at $dest -- nothing to remove."
      return 0
    fi
    if [ "$dry_run" = true ]; then
      echo "[dry-run] ${which}: would remove $dest and refresh the trust store"
      return 0
    fi
    rm -f "$dest"
    linux_refresh
    echo "${which}: removed $dest, trust store refreshed"
    return 0
  fi

  if [ -f "$dest" ] && [ "$(fingerprint_of "$dest")" = "$fp" ]; then
    echo "${which}: already trusted -- $cn ($fp) at $dest [source: $source_desc]"
    return 0
  fi
  if [ "$dry_run" = true ]; then
    echo "[dry-run] ${which}: would install $cn ($fp) to $dest [source: $source_desc]"
    return 0
  fi
  cp "$cert_file" "$dest"
  chmod 0644 "$dest"
  linux_refresh
  echo "${which}: trusted $cn ($fp) at $dest [source: $source_desc]"
}

# ---- apply: unrecognized platform ----

apply_unsupported() {
  local which="$1" cert_file="$2"
  echo "ERROR: don't recognize this platform's trust store (checked Darwin, /etc/pki/ca-trust/source/anchors, /usr/local/share/ca-certificates)." >&2
  echo "The ${which} CA has been saved to: $cert_file" >&2
  echo "Trust it by hand, e.g. for an NSS store:" >&2
  echo "  certutil -d sql:\$HOME/.pki/nssdb -A -t 'C,,' -n 'openshift-${account_alias}-${which}' -i $cert_file" >&2
  had_error=true
}

apply_ca() {
  local which="$1" cert_file="$2" source_desc="$3"
  case "$platform" in
    macos) apply_macos "$which" "$cert_file" "$source_desc" ;;
    rhel | debian) apply_linux "$which" "$cert_file" "$source_desc" ;;
    *) apply_unsupported "$which" "$cert_file" ;;
  esac
}

# ---- main ----

if [ "$want_api" = true ]; then
  if acquire_api_ca; then
    persisted=$(persist_ca api "$api_ca_file")
    apply_ca api "$persisted" "$api_ca_source"
  else
    had_error=true
  fi
fi

if [ "$want_ingress" = true ]; then
  if acquire_ingress_ca; then
    persisted=$(persist_ca ingress "$ingress_ca_file")
    apply_ca ingress "$persisted" "$ingress_ca_source"
  else
    had_error=true
  fi
fi

if [ "$had_error" = true ]; then
  exit 1
fi
exit 0
