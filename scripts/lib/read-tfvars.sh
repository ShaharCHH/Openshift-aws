#!/usr/bin/env bash
# Shared helper: read a single key's value out of a Terraform .tfvars file.
# Usage: value=$(read_tfvar existing_vpc_id accounts/horizon.tfvars)
#
# Uses [[:space:]] (POSIX), not \s (a GNU-only regex extension). BSD sed/grep
# (macOS's default /usr/bin/sed) doesn't support \s and silently fails to
# match, returning the input line completely unprocessed -- this bit us once
# already in scripts/preflight/run-all.sh.
#
# Prints "" (not an error) when the key isn't in the file -- callers that
# treat a key as optional (e.g. `x=$(read_tfvar foo "$f"); x="${x:-default}"`)
# depend on this. Without the trailing `|| true`, grep's exit 1 on no-match
# propagates through the pipeline under `pipefail` and kills the whole
# calling script before any fallback ever runs -- this bit us once already
# in scripts/ignition/render-install-config.sh.
read_tfvar() {
  local key="$1" file="$2"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -1 | \
    sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' || true
}
