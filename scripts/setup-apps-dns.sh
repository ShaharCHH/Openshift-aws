#!/usr/bin/env bash
# Makes every *.apps.<cluster>.<domain> name resolve to 127.0.0.1 on this
# machine, so the console, the registry route and anything else deployed to
# the cluster all reach the SSM tunnel by their real hostnames.
#
# WHY A RESOLVER AND NOT /etc/hosts: one 443 tunnel already carries every
# *.apps hostname -- SSM forwards a PORT, and HAProxy and the router dispatch
# on SNI and Host, so nothing about the tunnel is per-hostname. DNS is the
# only per-hostname part, and /etc/hosts has no wildcard. This cluster was
# already serving 9 routes (console, downloads, oauth, four monitoring
# routes, the registry, plus a deployed app) and every one of them needed its
# own line. The bastion's CoreDNS does answer *.apps with a wildcard, but it
# answers with a private VPC address that means nothing from a laptop.
#
# macOS solves this with /etc/resolver/<domain>: any name under that domain
# gets sent to the nameserver named there. Point it at a local dnsmasq that
# answers the whole zone with 127.0.0.1 and the wildcard works for names that
# do not exist yet -- an app deployed tomorrow needs no change here.
#
# Reads the domain from accounts/<alias>.tfvars, so like the other day-2
# scripts this needs no terraform state and no particular working directory.
#
# macOS only: /etc/resolver is a macOS resolver feature with no Linux
# equivalent (Linux would use systemd-resolved or an NSS module instead).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  cat >&2 <<'EOF'
usage: setup-apps-dns.sh -a <account-alias> [--uninstall] [--dry-run]

Points *.apps.<cluster>.<domain> at 127.0.0.1 via dnsmasq + /etc/resolver,
so every route on the cluster reaches the SSM tunnel by its real hostname
without an /etc/hosts line each.

  --uninstall   remove the dnsmasq drop-in and the resolver file
  --dry-run     show what would happen; changes nothing, needs no root

Needs dnsmasq installed (brew install dnsmasq) and root to write
/etc/resolver. The tunnel itself is separate: scripts/tunnel.sh -a <alias>.
EOF
  exit 1
}

account_alias=""
mode="install"
dry_run=false
cli_flags=""

while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
      shift 2
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

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this script is macOS-only -- /etc/resolver is a macOS resolver feature." >&2
  echo "On Linux, point systemd-resolved at the same wildcard instead." >&2
  exit 1
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

apps_domain="apps.${cluster_name}.${base_domain}"
resolver_file="/etc/resolver/${apps_domain}"

# ---- dnsmasq ----
#
# Checked, never installed. Same stance as tunnel.sh's session-manager-plugin
# check: a script that reaches into the machine's package manager on its own
# is a worse surprise than one that tells you what is missing.
command -v brew >/dev/null 2>&1 || {
  echo "ERROR: brew not found on PATH -- needed to locate dnsmasq's config directory." >&2
  exit 1
}
brew_prefix=$(brew --prefix 2>/dev/null)
[ -n "$brew_prefix" ] || {
  echo "ERROR: 'brew --prefix' returned nothing." >&2
  exit 1
}
# Resolved at runtime rather than hardcoded: /opt/homebrew on Apple silicon,
# /usr/local on Intel.
dnsmasq_conf="${brew_prefix}/etc/dnsmasq.conf"
dnsmasq_dropin_dir="${brew_prefix}/etc/dnsmasq.d"
dnsmasq_dropin="${dnsmasq_dropin_dir}/openshift-${account_alias}.conf"

if [ "$mode" = "install" ] && ! command -v dnsmasq >/dev/null 2>&1; then
  if [ "$dry_run" = true ]; then
    echo "NOTE: dnsmasq not found on PATH -- a real run would need 'brew install dnsmasq' first." >&2
  else
    echo "ERROR: dnsmasq not found on PATH." >&2
    echo "  brew install dnsmasq" >&2
    exit 1
  fi
fi

needs_root=true
[ "$dry_run" = true ] && needs_root=false
if [ "$needs_root" = true ] && [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: writing $resolver_file and restarting dnsmasq both need root." >&2
  echo "Re-run as:" >&2
  echo "  sudo $0 -a ${account_alias}${cli_flags}" >&2
  exit 1
fi

echo "account: ${account_alias}   wildcard domain: *.${apps_domain}"

# dnsmasq must be restarted as root -- it binds :53. Under sudo, `brew
# services` is already running as root, so no -u dance is needed here.
restart_dnsmasq() {
  if [ "$dry_run" = true ]; then
    echo "[dry-run] would restart dnsmasq (brew services restart dnsmasq)"
    return 0
  fi
  echo "restarting dnsmasq..."
  brew services restart dnsmasq >/dev/null 2>&1 || {
    echo "WARNING: 'brew services restart dnsmasq' failed -- restart it by hand." >&2
    return 1
  }
}

# ---- uninstall ----

if [ "$mode" = "uninstall" ]; then
  removed=false
  if [ -f "$dnsmasq_dropin" ]; then
    if [ "$dry_run" = true ]; then
      echo "[dry-run] would remove $dnsmasq_dropin"
    else
      rm -f "$dnsmasq_dropin"
      echo "removed $dnsmasq_dropin"
    fi
    removed=true
  else
    echo "$dnsmasq_dropin not present -- nothing to remove."
  fi
  if [ -f "$resolver_file" ]; then
    if [ "$dry_run" = true ]; then
      echo "[dry-run] would remove $resolver_file"
    else
      rm -f "$resolver_file"
      echo "removed $resolver_file"
    fi
    removed=true
  else
    echo "$resolver_file not present -- nothing to remove."
  fi
  [ "$removed" = true ] && restart_dnsmasq
  echo
  echo "Names under *.${apps_domain} will stop resolving to 127.0.0.1."
  echo "Any /etc/hosts entries you kept still apply -- this touched none of them."
  exit 0
fi

# ---- install ----

# A drop-in nothing reads is the silent failure mode here: dnsmasq only picks
# up the .d directory if the main config says so, and a machine that has had
# dnsmasq.conf hand-edited may not.
if [ ! -f "$dnsmasq_conf" ]; then
  echo "WARNING: $dnsmasq_conf not found -- cannot confirm the drop-in directory is read." >&2
elif ! grep -qE '^[[:space:]]*conf-dir=.*dnsmasq\.d' "$dnsmasq_conf"; then
  echo "WARNING: $dnsmasq_conf has no active 'conf-dir=...dnsmasq.d' line, so the" >&2
  echo "         drop-in below will be written and then ignored. Add:" >&2
  echo "           conf-dir=${dnsmasq_dropin_dir}/,*.conf" >&2
  echo "         (left for you to add -- this is dnsmasq's own config, not this repo's)" >&2
fi

if [ "$dry_run" = true ]; then
  echo "[dry-run] would write $dnsmasq_dropin:"
  echo "            address=/${apps_domain}/127.0.0.1"
  echo "[dry-run] would write $resolver_file:"
  echo "            nameserver 127.0.0.1"
  restart_dnsmasq
else
  mkdir -p "$dnsmasq_dropin_dir"
  cat >"$dnsmasq_dropin" <<EOF
# Managed by scripts/setup-apps-dns.sh -- account alias: ${account_alias}
# Every name under this cluster's ingress wildcard answers 127.0.0.1, where
# scripts/tunnel.sh is forwarding 443 to the bastion's HAProxy.
address=/${apps_domain}/127.0.0.1
EOF
  echo "wrote $dnsmasq_dropin"

  mkdir -p /etc/resolver
  cat >"$resolver_file" <<EOF
# Managed by scripts/setup-apps-dns.sh -- account alias: ${account_alias}
nameserver 127.0.0.1
EOF
  echo "wrote $resolver_file"

  restart_dnsmasq
fi

cat <<EOF

Check it with dscacheutil, NOT dig:

  dscacheutil -q host -a name anything-at-all.${apps_domain}

dig and nslookup query DNS servers directly and honor neither /etc/hosts nor
/etc/resolver, so they report NXDOMAIN for names every real application
resolves fine. A name with no route behind it is the better test -- it proves
the wildcard rather than an /etc/hosts line you already had.

Still needed to actually reach the cluster:
  - scripts/tunnel.sh -a ${account_alias} --all   (forwards 6443 and 443)
  - scripts/trust-cluster-ca.sh -a ${account_alias}   (so TLS verifies)
EOF
